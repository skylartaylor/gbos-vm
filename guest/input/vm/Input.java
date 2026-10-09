// Guest input helper for the Googlebook VM, run with app_process as
// the shell user. It connects out to the viewer on the host (10.0.2.2 is the
// host loopback under QEMU user networking, 10.0.2.100 in isolated mode) and, on its request, injects
// absolute mouse events and syncs clipboard text. Same approach as scrcpy's
// server (InputManager injection as shell), with a small line protocol:
//   host -> guest:  G width height | M x y | D button | U button | S hscroll vscroll | X | K keycode | C base64-text
//   guest -> host:  c base64-text (guest clipboard changed) | m tablet|inject (pointer mode)
// Both ends prove the per boot token with an HMAC exchange; the token is never sent. It arrives
// over the serial console and vm-host-control writes it to TOKEN_FILE, readable only by shell:
//   host -> guest:  N host-nonce
//   guest -> host:  a guest-nonce HMAC-SHA256(token, "gbos-guest:" host-nonce ":" guest-nonce)
//   host -> guest:  A HMAC-SHA256(token, "gbos-host:" guest-nonce ":" host-nonce)
// Nothing else is sent or accepted until it succeeds.
// Pointer mode "tablet": a uinput drawing-tablet device (absolute stylus on a
// non-direct device), which makes Android draw its own cursor at the exact
// position. If that cannot be created, events are injected instead and the
// host cursor is the pointer.
package vm;

import android.content.ClipData;
import android.os.IBinder;
import android.os.SystemClock;
import android.util.Base64;
import android.view.InputDevice;
import android.view.InputEvent;
import android.view.KeyEvent;
import android.view.MotionEvent;
import java.io.BufferedReader;
import java.io.FileReader;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.lang.reflect.Method;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.security.MessageDigest;
import java.security.SecureRandom;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

public final class Input {
    private static final String SHELL = "com.android.shell";
    private static Object inputManager;
    private static Method inject, setActionButton;
    private static Object clipboard;
    private static long downTime;
    private static int buttons;
    private static float x, y;
    private static volatile String lastClip = "";
    private static volatile OutputStream out;
    private static final String TOKEN_FILE = "/data/local/tmp/vm-input.token";
    private static String token = "", host = "10.0.2.2";
    private static boolean authed;
    private static final SecureRandom random = new SecureRandom();
    private static Process uinput;
    private static OutputStream tablet;
    private static int tabletW, tabletH;
    private static int tabletDeviceId;

    public static void main(String[] args) throws Exception {
        int port = args.length > 0 ? Integer.parseInt(args[0]) : 27183;
        Class<?> c;
        try { c = Class.forName("android.hardware.input.InputManagerGlobal"); }
        catch (ClassNotFoundException e) { c = Class.forName("android.hardware.input.InputManager"); }
        inputManager = c.getMethod("getInstance").invoke(null);
        inject = inputManager.getClass().getMethod("injectInputEvent", InputEvent.class, int.class);
        setActionButton = MotionEvent.class.getMethod("setActionButton", int.class);
        try {
            IBinder b = (IBinder) Class.forName("android.os.ServiceManager").getMethod("getService", String.class).invoke(null, "clipboard");
            clipboard = Class.forName("android.content.IClipboard$Stub").getMethod("asInterface", IBinder.class).invoke(null, b);
        } catch (Throwable t) { System.out.println("VM_INPUT clipboard unavailable: " + t); }
        System.out.println("VM_INPUT ready");
        Thread poll = new Thread(Input::pollClipboard, "clip");
        poll.setDaemon(true);
        poll.start();
        boolean waiting = false;
        while (true) {
            // No token, no connection.
            if (!loadToken()) {
                if (!waiting) System.out.println("VM_INPUT waiting for the host's token");
                waiting = true;
                SystemClock.sleep(2000);
                continue;
            }
            waiting = false;
            try (Socket s = new Socket()) {
                s.connect(new InetSocketAddress(host, port), 2000);
                s.setTcpNoDelay(true);
                authed = false;
                OutputStream link = s.getOutputStream();
                System.out.println("VM_INPUT connected");
                BufferedReader r = new BufferedReader(new InputStreamReader(s.getInputStream(), "UTF-8"));
                String line, guestNonce = null, expected = null;
                while ((line = readLine(r, authed ? 1 << 20 : 256)) != null) {
                    if (!authed) {
                        if (guestNonce == null && line.matches("N [0-9a-f]{32}")) {
                            String hostNonce = line.substring(2);
                            guestNonce = nonce();
                            expected = "A " + hmac("gbos-host:" + guestNonce + ":" + hostNonce);
                            link.write(("a " + guestNonce + " " + hmac("gbos-guest:" + hostNonce + ":" + guestNonce) + "\n").getBytes("UTF-8"));
                            link.flush();
                            continue;
                        }
                        if (expected == null || !MessageDigest.isEqual(line.getBytes("UTF-8"), expected.getBytes("UTF-8"))) {
                            System.out.println("VM_INPUT rejected host: bad token");
                            break;
                        }
                        authed = true; out = link;
                        continue;
                    }
                    if (line.startsWith("A ")) continue;
                    try { handle(line); } catch (Throwable t) {
                        Throwable cause = t.getCause() != null ? t.getCause() : t;
                        System.out.println("VM_INPUT error " + line.charAt(0) + ": " + cause);
                        // system_server restarted: our binder handles are dead, so start over.
                        if (cause instanceof android.os.DeadObjectException || String.valueOf(cause).contains("DeadSystem")) System.exit(3);
                    }
                }
            } catch (Throwable t) { /* host not listening yet */ }
            out = null;
            releaseAll();
            SystemClock.sleep(2000);
        }
    }

    /** One line, or null at end of stream or when a line exceeds max. */
    private static String readLine(BufferedReader r, int max) throws java.io.IOException {
        StringBuilder sb = new StringBuilder();
        int c;
        while ((c = r.read()) >= 0) {
            if (c == '\n') return sb.toString();
            if (sb.length() >= max) return null;
            sb.append((char) c);
        }
        return null;
    }

    private static boolean loadToken() {
        try (BufferedReader f = new BufferedReader(new FileReader(TOKEN_FILE))) {
            String t = f.readLine(), h = f.readLine();
            if (t == null || !t.matches("[0-9a-f]{32}")) return false;
            token = t;
            host = "10.0.2.100".equals(h) ? h : "10.0.2.2";
            return true;
        } catch (Exception e) { return false; }
    }

    private static String nonce() {
        byte[] b = new byte[16];
        random.nextBytes(b);
        return hex(b);
    }

    private static String hmac(String msg) throws Exception {
        Mac m = Mac.getInstance("HmacSHA256");
        m.init(new SecretKeySpec(token.getBytes("UTF-8"), "HmacSHA256"));
        return hex(m.doFinal(msg.getBytes("UTF-8")));
    }

    private static String hex(byte[] b) {
        StringBuilder sb = new StringBuilder(b.length * 2);
        for (byte v : b) sb.append(Character.forDigit((v >> 4) & 15, 16)).append(Character.forDigit(v & 15, 16));
        return sb.toString();
    }

    private static void handle(String line) throws Exception {
        if (line.isEmpty()) return;
        String[] p = line.split(" ");
        switch (line.charAt(0)) {
            case 'G': registerTablet(Integer.parseInt(p[1]), Integer.parseInt(p[2])); break;
            case 'M':
                x = Float.parseFloat(p[1]); y = Float.parseFloat(p[2]);
                if (tabletAlive()) { tabletSend("3,0," + Math.round(x) + ",3,1," + Math.round(y) + ",1,320,1,0,0,0"); break; }
                motion(buttons != 0 ? MotionEvent.ACTION_MOVE : MotionEvent.ACTION_HOVER_MOVE, 0, 0, 0);
                break;
            case 'D': {
                int b = Integer.parseInt(p[1]);
                if (tabletAlive()) { buttons |= b; tabletSend((b == 2 ? "1,273,1," : b == 4 ? "1,274,1," : "") + "1,330,1,3,24,255,0,0,0"); break; }
                if (buttons == 0) { downTime = SystemClock.uptimeMillis(); buttons |= b; motion(MotionEvent.ACTION_DOWN, 0, 0, 0); }
                else buttons |= b;
                motion(MotionEvent.ACTION_BUTTON_PRESS, b, 0, 0);
                break;
            }
            case 'U': {
                int b = Integer.parseInt(p[1]);
                if ((buttons & b) == 0) break;
                buttons &= ~b;
                if (tabletAlive()) { tabletSend((b == 2 ? "1,273,0," : b == 4 ? "1,274,0," : "") + (buttons == 0 ? "1,330,0,3,24,0," : "") + "0,0,0"); break; }
                motion(MotionEvent.ACTION_BUTTON_RELEASE, b, 0, 0);
                if (buttons == 0) motion(MotionEvent.ACTION_UP, 0, 0, 0);
                break;
            }
            case 'S': {
                float hs = Float.parseFloat(p[1]), vs = Float.parseFloat(p[2]);
                if (tabletAlive()) {
                    // The tablet's wheel axes are ignored by this Android build, and a scroll injected as a
                    // separate mouse makes apps un-hide the idle system mouse cursor and gets dropped while
                    // the tablet hovers. So inject the scroll as if it came from the tablet itself.
                    if (tabletDeviceId == 0) tabletDeviceId = findTabletDevice();
                    if (tabletDeviceId != 0) scrollAs(tabletDeviceId, InputDevice.SOURCE_MOUSE | InputDevice.SOURCE_STYLUS, MotionEvent.TOOL_TYPE_STYLUS, hs, vs);
                    break;
                }
                motion(MotionEvent.ACTION_SCROLL, 0, hs, vs);
                break;
            }
            case 'X':
                if (tabletAlive()) { if (buttons == 0) tabletSend("1,320,0,0,0,0"); break; }
                if (buttons == 0) motion(MotionEvent.ACTION_HOVER_EXIT, 0, 0, 0);
                break;
            case 'K': key(Integer.parseInt(p[1])); break;
            case 'C': setClip(p.length > 1 ? new String(Base64.decode(p[1], Base64.NO_WRAP), "UTF-8") : ""); break;
            default: break;
        }
    }

    private static boolean tabletAlive() {
        if (tablet == null) return false;
        if (uinput.isAlive()) return true;
        tablet = null; buttons = 0;
        System.out.println("VM_INPUT tablet process ended; injecting instead");
        reply("m inject");
        return false;
    }

    private static void tabletSend(String events) {
        try {
            tablet.write(("{\"id\":1,\"command\":\"inject\",\"events\":[" + events + "]}\n").getBytes("UTF-8"));
            tablet.flush();
        } catch (Throwable t) { tablet = null; }
    }

    // BTN_TOOL_PEN 320, BTN_TOUCH 330, BTN_RIGHT 273, BTN_MIDDLE 274; ABS_X 0, ABS_Y 1, ABS_PRESSURE 24.
    private static void registerTablet(int w, int h) {
        if (tablet != null && uinput.isAlive() && w == tabletW && h == tabletH) { reply("m tablet"); return; }
        if (w <= 0 || h <= 0) {   // host asked for injection mode (Mac cursor is the pointer)
            if (uinput != null) uinput.destroy();
            tablet = null; buttons = 0; tabletW = tabletH = 0;
            reply("m inject");
            return;
        }
        try {
            if (uinput != null) uinput.destroy();
            tablet = null; buttons = 0;
            uinput = new ProcessBuilder("/system/bin/uinput", "-").redirectErrorStream(true).start();
            OutputStream o = uinput.getOutputStream();
            String axis = "{\"value\":0,\"minimum\":0,\"maximum\":%d,\"fuzz\":0,\"flat\":0,\"resolution\":0}";
            o.write(("{\"id\":1,\"command\":\"register\",\"name\":\"VM Absolute Pointer\",\"vid\":6900,\"pid\":30465,\"bus\":\"usb\","
                    + "\"configuration\":[{\"type\":100,\"data\":[1,3]},{\"type\":101,\"data\":[273,274,320,330]},{\"type\":103,\"data\":[0,1,24]}],"
                    + "\"abs_info\":[{\"code\":0,\"info\":" + String.format(axis, w - 1) + "},{\"code\":1,\"info\":" + String.format(axis, h - 1) + "},{\"code\":24,\"info\":" + String.format(axis, 255) + "}]}\n").getBytes("UTF-8"));
            o.flush();
            SystemClock.sleep(1500);
            if (!uinput.isAlive()) throw new IllegalStateException("uinput exited " + uinput.exitValue());
            tablet = o; tabletW = w; tabletH = h; tabletDeviceId = findTabletDevice();
            System.out.println("VM_INPUT tablet registered " + w + "x" + h + " device " + tabletDeviceId);
            drain(uinput, "uinput");
            reply("m tablet");
        } catch (Throwable t) {
            tablet = null;
            System.out.println("VM_INPUT tablet unavailable: " + t);
            reply("m inject");
        }
    }

    private static void drain(Process process, String tag) {
        Thread t = new Thread(() -> {
            try (BufferedReader r = new BufferedReader(new InputStreamReader(process.getInputStream()))) {
                String line; int n = 0;
                while ((line = r.readLine()) != null && n++ < 40) System.out.println("VM_INPUT " + tag + ": " + line);
            } catch (Throwable e) { /* process ended */ }
        }, tag);
        t.setDaemon(true);
        t.start();
    }

    private static void reply(String line) {
        OutputStream o = out;
        if (o == null) return;
        try { synchronized (Input.class) { o.write((line + "\n").getBytes("UTF-8")); o.flush(); } } catch (Throwable t) { /* link closed */ }
    }

    private static void releaseAll() {
        try {
            for (int b = 1; b <= 4 && buttons != 0; b <<= 1) if ((buttons & b) != 0) handle("U " + b);
        } catch (Throwable t) { buttons = 0; }
    }

    private static void motion(int action, int actionButton, float hscroll, float vscroll) throws Exception {
        long now = SystemClock.uptimeMillis();
        MotionEvent.PointerProperties[] props = { new MotionEvent.PointerProperties() };
        props[0].id = 0;
        props[0].toolType = MotionEvent.TOOL_TYPE_MOUSE;
        MotionEvent.PointerCoords[] coords = { new MotionEvent.PointerCoords() };
        coords[0].x = x; coords[0].y = y;
        coords[0].pressure = buttons != 0 ? 1f : 0f;
        coords[0].size = 1f;
        coords[0].setAxisValue(MotionEvent.AXIS_HSCROLL, hscroll);
        coords[0].setAxisValue(MotionEvent.AXIS_VSCROLL, vscroll);
        MotionEvent e = MotionEvent.obtain(buttons != 0 || action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_BUTTON_RELEASE ? downTime : now,
                now, action, 1, props, coords, 0, buttons, 1f, 1f, 0, 0, InputDevice.SOURCE_MOUSE, 0);
        if (actionButton != 0) setActionButton.invoke(e, actionButton);
        inject.invoke(inputManager, e, 0);
        e.recycle();
    }

    private static int findTabletDevice() {
        try {
            for (int id : InputDevice.getDeviceIds()) {
                InputDevice d = InputDevice.getDevice(id);
                if (d != null && "VM Absolute Pointer".equals(d.getName())) return id;
            }
        } catch (Throwable t) { System.out.println("VM_INPUT device lookup: " + t); }
        return 0;
    }

    private static void scrollAs(int deviceId, int source, int toolType, float hscroll, float vscroll) throws Exception {
        long now = SystemClock.uptimeMillis();
        MotionEvent.PointerProperties[] props = { new MotionEvent.PointerProperties() };
        props[0].id = 0;
        props[0].toolType = toolType;
        MotionEvent.PointerCoords[] coords = { new MotionEvent.PointerCoords() };
        coords[0].x = Math.round(x); coords[0].y = Math.round(y);
        coords[0].setAxisValue(MotionEvent.AXIS_HSCROLL, hscroll);
        coords[0].setAxisValue(MotionEvent.AXIS_VSCROLL, vscroll);
        MotionEvent e = MotionEvent.obtain(now, now, MotionEvent.ACTION_SCROLL, 1, props, coords, 0, 0, 1f, 1f, deviceId, 0, source, 0);
        inject.invoke(inputManager, e, 0);
        e.recycle();
    }

    private static void key(int code) throws Exception {
        long now = SystemClock.uptimeMillis();
        for (int action : new int[] { KeyEvent.ACTION_DOWN, KeyEvent.ACTION_UP }) {
            inject.invoke(inputManager, new KeyEvent(now, now, action, code, 0, 0, -1, 0, 0, InputDevice.SOURCE_KEYBOARD), 0);
        }
    }

    private static int currentUser() {
        try { return (Integer) Class.forName("android.app.ActivityManager").getMethod("getCurrentUser").invoke(null); }
        catch (Throwable t) { return 0; }
    }

    // IClipboard signatures change between releases; fill arguments by type.
    private static Object callClipboard(String name, ClipData clip) throws Exception {
        if (clipboard == null) return null;
        for (Method m : clipboard.getClass().getMethods()) {
            if (!m.getName().equals(name)) continue;
            Class<?>[] types = m.getParameterTypes();
            Object[] a = new Object[types.length];
            int strings = 0, ints = 0;
            for (int i = 0; i < types.length; i++) {
                if (types[i] == ClipData.class) a[i] = clip;
                else if (types[i] == String.class) a[i] = strings++ == 0 ? SHELL : null;
                else if (types[i] == int.class) a[i] = ints++ == 0 ? currentUser() : 0;
                else if (types[i] == boolean.class) a[i] = false;
            }
            return m.invoke(clipboard, a);
        }
        return null;
    }

    private static void setClip(String text) {
        try {
            lastClip = text;
            callClipboard("setPrimaryClip", ClipData.newPlainText("", text));
        } catch (Throwable t) { System.out.println("VM_INPUT setClip: " + t); }
    }

    private static void pollClipboard() {
        boolean reported = false;
        while (true) {
            SystemClock.sleep(700);
            OutputStream o = out;
            if (o == null) continue;
            try {
                ClipData clip = (ClipData) callClipboard("getPrimaryClip", null);
                if (clip == null || clip.getItemCount() == 0) continue;
                CharSequence cs = clip.getItemAt(0).getText();
                if (cs == null) continue;
                String text = cs.toString();
                if (text.equals(lastClip) || text.length() > 200000) continue;
                lastClip = text;
                byte[] msg = ("c " + Base64.encodeToString(text.getBytes("UTF-8"), Base64.NO_WRAP) + "\n").getBytes("UTF-8");
                synchronized (Input.class) { o.write(msg); o.flush(); }
            } catch (Throwable t) {
                if (!reported) { reported = true; System.out.println("VM_INPUT getClip: " + t + (t.getCause() != null ? " / " + t.getCause() : "")); }
            }
        }
    }
}
