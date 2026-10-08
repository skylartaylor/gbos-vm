// A UVC webcam for the guest backed by the Mac camera, over QEMU usb-redir. See webcam.h.
//
// Why usb-redir: QEMU on macOS has no virtual camera device, and the Mac's built-in camera is
// not a USB device it could pass through. usb-redir lets a process outside QEMU *be* a USB
// device. The guest kernel already has uvcvideo, so Android just sees a webcam being plugged
// in; image/mica_camera_port.py swaps in AOSP's V4L2 camera provider to serve it.
//
// The usb-redir protocol (spice/usbredir, usbredirproto.h) is implemented directly for the
// handful of packets a single bulk-streaming device needs, so no extra library is required.
// QEMU's XHCI controller only accepts a usb-redir peer with ep_info_max_packet_size,
// 64bits_ids and 32bits_bulk_length, so those are advertised along with
// connect_device_version. Hellos use the 32-bit id header; once both sides have
// 64bits_ids every later packet carries a 64-bit id.
#import "webcam.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <fcntl.h>
#include <unistd.h>

// --- usb-redir protocol subset -------------------------------------------------------------
enum { R_HELLO=0, R_DEVICE_CONNECT=1, R_RESET=3, R_INTERFACE_INFO=4, R_EP_INFO=5,
       R_SET_CONFIGURATION=6, R_GET_CONFIGURATION=7, R_CONFIGURATION_STATUS=8,
       R_SET_ALT_SETTING=9, R_GET_ALT_SETTING=10, R_ALT_SETTING_STATUS=11,
       R_CANCEL_DATA_PACKET=21, R_CONTROL_PACKET=100, R_BULK_PACKET=101 };
enum { ST_SUCCESS=0, ST_CANCELLED=1, ST_INVAL=2, ST_STALL=4 };
enum { CAP_CONNECT_DEVICE_VERSION=1, CAP_EP_INFO_MAX_PACKET_SIZE=4, CAP_64BITS_IDS=5, CAP_32BITS_BULK_LENGTH=6 };
#pragma pack(push,1)
typedef struct { uint8_t endpoint, request, requesttype, status; uint16_t value, index, length; } CtrlHdr;
// length_high is only on the wire when both sides have 32bits_bulk_length (see bulkHeaderLength).
typedef struct { uint8_t endpoint, status; uint16_t length; uint32_t stream_id; uint16_t length_high; } BulkHdr;
#pragma pack(pop)

// --- UVC device description ----------------------------------------------------------------
static const struct { uint16_t w, h; } kFrames[] = {{1280,720},{1920,1080},{640,480}};
enum { kFrameCount = 3, kInterval = 333333 /* 30 fps, 100 ns units */, kProbeLen = 34, kEpVideo = 0x81 };

// USB vendor:product id (the Linux webcam gadget's). The V4L2 provider accepts any UVC device,
// so the id only matters to anyone reading lsusb. GBOS_WEBCAM_ID=vvvv:pppp overrides it.
static uint16_t gVendor = 0x1d6b, gProduct = 0x0102;
static void LoadIds(void) {
  const char *e = getenv("GBOS_WEBCAM_ID"); unsigned v, p;
  if (e && sscanf(e, "%x:%x", &v, &p) == 2) { gVendor = v; gProduct = p; }
}

static void put8(NSMutableData *d, uint8_t v) { [d appendBytes:&v length:1]; }
static void put16(NSMutableData *d, uint16_t v) { put8(d, v & 0xff); put8(d, v >> 8); }
static void put32(NSMutableData *d, uint32_t v) { put16(d, v & 0xffff); put16(d, v >> 16); }

static NSData *DeviceDescriptor(void) {
  NSMutableData *d = [NSMutableData data];
  put8(d, 18); put8(d, 1); put16(d, 0x0200);
  put8(d, 0xEF); put8(d, 0x02); put8(d, 0x01);          // Miscellaneous / IAD
  put8(d, 64); put16(d, gVendor); put16(d, gProduct);
  put16(d, 0x0100); put8(d, 1); put8(d, 2); put8(d, 0); put8(d, 1);
  return d;
}

static NSData *ConfigDescriptor(void) {
  // Video control: camera input terminal (1) -> streaming output terminal (2), no interrupt EP.
  NSMutableData *vc = [NSMutableData data];
  put8(vc, 18); put8(vc, 0x24); put8(vc, 0x02); put8(vc, 1); put16(vc, 0x0201);
  put8(vc, 0); put8(vc, 0); put16(vc, 0); put16(vc, 0); put16(vc, 0); put8(vc, 3); put8(vc, 0); put8(vc, 0); put8(vc, 0);
  put8(vc, 9); put8(vc, 0x24); put8(vc, 0x03); put8(vc, 2); put16(vc, 0x0101); put8(vc, 0); put8(vc, 1); put8(vc, 0);
  NSMutableData *vcHeader = [NSMutableData data];
  put8(vcHeader, 13); put8(vcHeader, 0x24); put8(vcHeader, 0x01); put16(vcHeader, 0x0110);
  put16(vcHeader, 13 + vc.length); put32(vcHeader, 48000000); put8(vcHeader, 1); put8(vcHeader, 1);
  // Video streaming: one MJPEG format with three frame sizes, then colour matching.
  NSMutableData *vs = [NSMutableData data];
  put8(vs, 11); put8(vs, 0x24); put8(vs, 0x06); put8(vs, 1); put8(vs, kFrameCount);
  put8(vs, 1); put8(vs, 1); put8(vs, 0); put8(vs, 0); put8(vs, 0); put8(vs, 0);
  for (int i = 0; i < kFrameCount; i++) {
    uint32_t w = kFrames[i].w, h = kFrames[i].h, max = w * h * 2;
    put8(vs, 30); put8(vs, 0x24); put8(vs, 0x07); put8(vs, i + 1); put8(vs, 0);
    put16(vs, w); put16(vs, h); put32(vs, max * 8); put32(vs, max * 8 * 30); put32(vs, max);
    put32(vs, kInterval); put8(vs, 1); put32(vs, kInterval);
  }
  put8(vs, 6); put8(vs, 0x24); put8(vs, 0x0D); put8(vs, 1); put8(vs, 1); put8(vs, 4);
  NSMutableData *vsHeader = [NSMutableData data];
  put8(vsHeader, 14); put8(vsHeader, 0x24); put8(vsHeader, 0x01); put8(vsHeader, 1);
  put16(vsHeader, 14 + vs.length); put8(vsHeader, kEpVideo); put8(vsHeader, 0); put8(vsHeader, 2);
  put8(vsHeader, 0); put8(vsHeader, 0); put8(vsHeader, 0); put8(vsHeader, 1); put8(vsHeader, 0);

  NSMutableData *body = [NSMutableData data];
  put8(body, 8); put8(body, 0x0B); put8(body, 0); put8(body, 2); put8(body, 0x0E); put8(body, 0x03); put8(body, 0); put8(body, 2);
  put8(body, 9); put8(body, 4); put8(body, 0); put8(body, 0); put8(body, 0); put8(body, 0x0E); put8(body, 0x01); put8(body, 0); put8(body, 2);
  [body appendData:vcHeader]; [body appendData:vc];
  put8(body, 9); put8(body, 4); put8(body, 1); put8(body, 0); put8(body, 1); put8(body, 0x0E); put8(body, 0x02); put8(body, 0); put8(body, 0);
  [body appendData:vsHeader]; [body appendData:vs];
  put8(body, 7); put8(body, 5); put8(body, kEpVideo); put8(body, 0x02); put16(body, 512); put8(body, 0);

  NSMutableData *cfg = [NSMutableData data];
  put8(cfg, 9); put8(cfg, 2); put16(cfg, 9 + body.length); put8(cfg, 2); put8(cfg, 1); put8(cfg, 0); put8(cfg, 0x80); put8(cfg, 250);
  [cfg appendData:body];
  return cfg;
}

static NSData *StringDescriptor(uint8_t index) {
  NSMutableData *d = [NSMutableData data];
  if (index == 0) { put8(d, 4); put8(d, 3); put16(d, 0x0409); return d; }
  NSString *s = index == 1 ? @"gbos-vm" : index == 2 ? @"Mac Camera" : nil;
  if (!s) return nil;
  put8(d, 2 + 2 * s.length); put8(d, 3);
  for (NSUInteger i = 0; i < s.length; i++) put16(d, [s characterAtIndex:i]);
  return d;
}

static void FillProbe(uint8_t *p, uint8_t frame) {
  if (frame < 1 || frame > kFrameCount) frame = 1;
  uint32_t max = kFrames[frame - 1].w * kFrames[frame - 1].h * 2;
  memset(p, 0, kProbeLen);
  p[0] = 1; p[2] = 1; p[3] = frame;
  OSWriteLittleInt32(p, 4, kInterval);
  OSWriteLittleInt32(p, 18, max);       // dwMaxVideoFrameSize
  OSWriteLittleInt32(p, 22, max);       // dwMaxPayloadTransferSize: one bulk payload per frame
  OSWriteLittleInt32(p, 26, 48000000);
  p[30] = 3; p[31] = 1; p[32] = 1; p[33] = 1;
}

// --- The device ----------------------------------------------------------------------------
@interface GBWebcam () <AVCaptureVideoDataOutputSampleBufferDelegate>
@end

@implementation GBWebcam {
  NSString *_path;
  dispatch_queue_t _q, _captureQueue;
  int _fd;
  dispatch_source_t _readSource, _writeSource, _idleTimer;
  BOOL _writeSuspended, _stopped;
  NSMutableData *_in, *_out;
  uint32_t _peerCaps;
  BOOL _ids64, _bulk32;     // negotiated in the hello exchange
  uint8_t _configuration;
  uint8_t _probe[kProbeLen], _commit[kProbeLen];
  // Bulk IN requests from the guest waiting for frame data, oldest first.
  NSMutableArray<NSArray<NSNumber *> *> *_pending;
  NSData *_frame, *_nextFrame;
  NSUInteger _frameOffset;
  BOOL _needZeroLength, _fid;
  NSUInteger _framesSent;
  CFAbsoluteTime _lastRequest;
  // Capture, touched on _captureQueue except where noted.
  AVCaptureSession *_session;
  CIContext *_ci;
  CGColorSpaceRef _srgb;
  int _targetW, _targetH;   // written on _q, read on _captureQueue; a torn read only costs a frame
  BOOL _capturing;          // _q only
}

- (instancetype)initWithSocketPath:(NSString *)path {
  if (!(self = [super init])) return nil;
  _path = [path copy]; _fd = -1; LoadIds();
  _q = dispatch_queue_create("gbos.webcam", DISPATCH_QUEUE_SERIAL);
  _captureQueue = dispatch_queue_create("gbos.webcam.capture", DISPATCH_QUEUE_SERIAL);
  _pending = [NSMutableArray array];
  _ci = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
  _srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  FillProbe(_probe, 1); FillProbe(_commit, 1);
  return self;
}

- (void)dealloc { CGColorSpaceRelease(_srgb); }

- (void)start { dispatch_async(_q, ^{ self->_stopped = NO; [self connect]; }); }

- (void)stop {
  dispatch_sync(_q, ^{ self->_stopped = YES; [self disconnect]; });
}

// --- Socket ---------------------------------------------------------------------------------
- (void)connect {
  if (_stopped || _fd >= 0) return;
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  struct sockaddr_un a = {.sun_family = AF_UNIX};
  strlcpy(a.sun_path, _path.fileSystemRepresentation, sizeof a.sun_path);
  if (fd < 0 || connect(fd, (struct sockaddr *)&a, sizeof a) != 0) {
    if (fd >= 0) close(fd);
    // QEMU creates the socket shortly after it starts; keep trying while we are wanted.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), _q, ^{ [self connect]; });
    return;
  }
  fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
  int one = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
  _fd = fd; _in = [NSMutableData data]; _out = [NSMutableData data]; _peerCaps = 0; _configuration = 0;
  _ids64 = _bulk32 = NO;
  _readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, _q);
  dispatch_source_set_event_handler(_readSource, ^{ [self readable]; });
  dispatch_resume(_readSource);
  _writeSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE, fd, 0, _q);
  dispatch_source_set_event_handler(_writeSource, ^{ [self flush]; });
  _writeSuspended = YES;
  _idleTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _q);
  dispatch_source_set_timer(_idleTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 4);
  dispatch_source_set_event_handler(_idleTimer, ^{
    // Turn the Mac camera (and its green light) off once the guest stops pulling frames. Requests
    // still waiting for a frame (say, while macOS asks for camera access) mean it hasn't.
    if (self->_capturing && self->_pending.count == 0 && CFAbsoluteTimeGetCurrent() - self->_lastRequest > 3) [self stopCapture];
  });
  dispatch_resume(_idleTimer);
  // Hello: 64-byte version string, then our capability bits.
  uint8_t hello[68] = {0};
  strlcpy((char *)hello, "gbos-vm webcam 1", 64);
  uint32_t caps = (1u << CAP_CONNECT_DEVICE_VERSION) | (1u << CAP_EP_INFO_MAX_PACKET_SIZE) |
                  (1u << CAP_64BITS_IDS) | (1u << CAP_32BITS_BULK_LENGTH);
  OSWriteLittleInt32(hello, 64, caps);
  [self send:R_HELLO id:0 header:hello length:sizeof hello data:nil];
  NSLog(@"webcam: connected to %@", _path);
}

- (void)disconnect {
  [self stopCapture];
  if (_readSource) { dispatch_source_cancel(_readSource); _readSource = nil; }
  if (_writeSource) { if (_writeSuspended) dispatch_resume(_writeSource); dispatch_source_cancel(_writeSource); _writeSource = nil; }
  if (_idleTimer) { dispatch_source_cancel(_idleTimer); _idleTimer = nil; }
  if (_fd >= 0) { close(_fd); _fd = -1; }
  [_pending removeAllObjects]; _frame = _nextFrame = nil; _needZeroLength = NO;
}

- (void)readable {
  uint8_t buf[65536];
  for (;;) {
    ssize_t n = read(_fd, buf, sizeof buf);
    if (n > 0) { [_in appendBytes:buf length:n]; continue; }
    if (n < 0 && errno == EAGAIN) break;
    NSLog(@"webcam: QEMU closed the link");
    [self disconnect];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), _q, ^{ [self connect]; });
    return;
  }
  const uint8_t *p = _in.bytes; NSUInteger used = 0;
  for (;;) {
    NSUInteger hl = _ids64 ? 16 : 12;
    if (_in.length - used < hl) break;
    uint32_t type = OSReadLittleInt32(p + used, 0), len = OSReadLittleInt32(p + used, 4);
    uint64_t pid = _ids64 ? OSReadLittleInt64(p + used, 8) : OSReadLittleInt32(p + used, 8);
    if (_in.length - used < hl + (NSUInteger)len) break;
    [self packet:type id:pid body:p + used + hl length:len];   // may switch _ids64 (hello)
    if (_fd < 0) return;
    used += hl + len;
  }
  [_in replaceBytesInRange:NSMakeRange(0, used) withBytes:NULL length:0];
}

- (void)send:(uint32_t)type id:(uint64_t)pid header:(const void *)h length:(NSUInteger)hl data:(NSData *)data {
  if (_fd < 0) return;
  uint8_t hdr[16];
  OSWriteLittleInt32(hdr, 0, type); OSWriteLittleInt32(hdr, 4, (uint32_t)(hl + data.length));
  BOOL wide = _ids64 && type != R_HELLO;
  if (wide) OSWriteLittleInt64(hdr, 8, pid); else OSWriteLittleInt32(hdr, 8, (uint32_t)pid);
  [_out appendBytes:hdr length:wide ? 16 : 12];
  if (hl) [_out appendBytes:h length:hl];
  if (data.length) [_out appendData:data];
  [self flush];
}

- (void)flush {
  while (_out.length) {
    ssize_t n = write(_fd, _out.bytes, _out.length);
    if (n > 0) { [_out replaceBytesInRange:NSMakeRange(0, n) withBytes:NULL length:0]; continue; }
    if (n < 0 && errno == EAGAIN) break;
    return;   // the read side notices the closed socket
  }
  BOOL wantWrite = _out.length > 0;
  if (wantWrite && _writeSuspended) { dispatch_resume(_writeSource); _writeSuspended = NO; }
  else if (!wantWrite && !_writeSuspended) { dispatch_suspend(_writeSource); _writeSuspended = YES; }
}

// --- Protocol -------------------------------------------------------------------------------
static BOOL Debug(void) { static int on = -1; if (on < 0) on = getenv("GBOS_WEBCAM_DEBUG") != NULL; return on; }

- (void)packet:(uint32_t)type id:(uint64_t)pid body:(const uint8_t *)b length:(uint32_t)len {
  if (Debug()) {
    if (type == R_CONTROL_PACKET && len >= sizeof(CtrlHdr)) {
      const CtrlHdr *c = (const void *)b;
      NSLog(@"webcam: ctrl id=%llu ep=%02x rt=%02x req=%02x val=%04x idx=%04x len=%u", pid, c->endpoint, c->requesttype, c->request, c->value, c->index, c->length);
    } else if (type != R_BULK_PACKET) NSLog(@"webcam: packet type=%u id=%llu len=%u", type, pid, len);
  }
  switch (type) {
    case R_HELLO:
      if (len >= 68) _peerCaps = OSReadLittleInt32(b, 64);
      _ids64 = (_peerCaps >> CAP_64BITS_IDS) & 1;
      _bulk32 = (_peerCaps >> CAP_32BITS_BULK_LENGTH) & 1;
      [self plugIn];
      break;
    case R_SET_CONFIGURATION: {
      uint8_t cfg = len ? b[0] : 0, ok = cfg <= 1;
      if (ok) _configuration = cfg;
      uint8_t st[2] = {ok ? ST_SUCCESS : ST_STALL, _configuration};
      [self send:R_CONFIGURATION_STATUS id:pid header:st length:2 data:nil];
      break; }
    case R_GET_CONFIGURATION: {
      uint8_t st[2] = {ST_SUCCESS, _configuration};
      [self send:R_CONFIGURATION_STATUS id:pid header:st length:2 data:nil];
      break; }
    case R_SET_ALT_SETTING: {
      uint8_t iface = len > 0 ? b[0] : 0, alt = len > 1 ? b[1] : 0;
      uint8_t st[3] = {(iface <= 1 && alt == 0) ? ST_SUCCESS : ST_INVAL, iface, 0};
      [self send:R_ALT_SETTING_STATUS id:pid header:st length:3 data:nil];
      break; }
    case R_GET_ALT_SETTING: {
      uint8_t st[3] = {ST_SUCCESS, len ? b[0] : 0, 0};
      [self send:R_ALT_SETTING_STATUS id:pid header:st length:3 data:nil];
      break; }
    case R_RESET:
      _configuration = 0; [_pending removeAllObjects]; [self stopCapture];
      break;
    case R_CANCEL_DATA_PACKET:
      for (NSUInteger i = 0; i < _pending.count; i++) if (_pending[i][0].unsignedLongLongValue == pid) {
        [_pending removeObjectAtIndex:i];
        [self sendBulk:pid endpoint:kEpVideo status:ST_CANCELLED data:nil];
        break;
      }
      break;
    case R_CONTROL_PACKET:
      if (len >= sizeof(CtrlHdr)) {
        CtrlHdr h; memcpy(&h, b, sizeof h);
        [self control:pid header:h data:b + sizeof h length:len - (uint32_t)sizeof h];
      }
      break;
    case R_BULK_PACKET:
      if (len >= [self bulkHeaderLength]) {
        BulkHdr h = {0}; memcpy(&h, b, [self bulkHeaderLength]);
        uint32_t want = h.length | (_bulk32 ? (uint32_t)h.length_high << 16 : 0);
        if (h.endpoint == kEpVideo) {
          [_pending addObject:@[@(pid), @(want)]];
          _lastRequest = CFAbsoluteTimeGetCurrent();
          if (!_capturing) [self startCapture];
          [self serve];
        } else {
          [self sendBulk:pid endpoint:h.endpoint status:ST_INVAL data:nil];
        }
      }
      break;
    default:
      break;   // nothing else is used by a device with no iso/interrupt endpoints
  }
}

- (void)plugIn {
  BOOL mps = (_peerCaps >> CAP_EP_INFO_MAX_PACKET_SIZE) & 1, ver = (_peerCaps >> CAP_CONNECT_DEVICE_VERSION) & 1;
  // ep_info: index = ((address & 0x80) >> 3) | (address & 0x0f).
  uint8_t ep[96 + 64] = {0};
  memset(ep, 255, 32);
  ep[0] = 0; ep[16] = 0;                     // control endpoint 0, both directions
  ep[17] = 2; ep[64 + 17] = 1;               // 0x81 bulk IN on interface 1
  OSWriteLittleInt16(ep, 96 + 0 * 2, 64); OSWriteLittleInt16(ep, 96 + 16 * 2, 64); OSWriteLittleInt16(ep, 96 + 17 * 2, 512);
  [self send:R_EP_INFO id:0 header:ep length:mps ? sizeof ep : 96 data:nil];
  uint8_t ii[4 + 128] = {0};
  OSWriteLittleInt32(ii, 0, 2);
  ii[4] = 0; ii[5] = 1; ii[36] = 0x0E; ii[37] = 0x0E; ii[68] = 0x01; ii[69] = 0x02;
  [self send:R_INTERFACE_INFO id:0 header:ii length:sizeof ii data:nil];
  uint8_t dc[10] = {2 /* high speed */, 0xEF, 0x02, 0x01};
  OSWriteLittleInt16(dc, 4, gVendor); OSWriteLittleInt16(dc, 6, gProduct); OSWriteLittleInt16(dc, 8, 0x0100);
  [self send:R_DEVICE_CONNECT id:0 header:dc length:ver ? 10 : 8 data:nil];
  NSLog(@"webcam: plugged in");
}

- (NSUInteger)bulkHeaderLength { return _bulk32 ? 10 : 8; }

- (void)sendBulk:(uint64_t)pid endpoint:(uint8_t)ep status:(uint8_t)status data:(NSData *)data {
  uint32_t n = (uint32_t)data.length;
  BulkHdr h = {ep, status, (uint16_t)(n & 0xffff), 0, (uint16_t)(n >> 16)};
  [self send:R_BULK_PACKET id:pid header:&h length:[self bulkHeaderLength] data:data];
}

- (void)reply:(uint64_t)pid header:(CtrlHdr)h status:(uint8_t)status data:(NSData *)data {
  if (data.length > h.length) data = [data subdataWithRange:NSMakeRange(0, h.length)];
  if (Debug()) NSLog(@"webcam:   -> id=%llu status=%u bytes=%lu", pid, status, (unsigned long)data.length);
  h.status = status;
  if (h.endpoint & 0x80) h.length = status == ST_SUCCESS ? data.length : 0;
  [self send:R_CONTROL_PACKET id:pid header:&h length:sizeof h data:(h.endpoint & 0x80) ? data : nil];
}

- (void)control:(uint64_t)pid header:(CtrlHdr)h data:(const uint8_t *)data length:(uint32_t)len {
  uint8_t type = h.value >> 8, idx = h.value & 0xff;
  if (h.requesttype == 0x80 && h.request == 6) {            // GET_DESCRIPTOR
    NSData *d = type == 1 ? DeviceDescriptor() : type == 2 ? ConfigDescriptor() : type == 3 ? StringDescriptor(idx) : nil;
    [self reply:pid header:h status:d ? ST_SUCCESS : ST_STALL data:d];
    return;
  }
  if ((h.requesttype & 0xfc) == 0x80 && h.request == 0) {   // GET_STATUS
    [self reply:pid header:h status:ST_SUCCESS data:[NSData dataWithBytes:"\0\0" length:2]];
    return;
  }
  if ((h.requesttype & 0xfc) == 0x00 && (h.request == 1 || h.request == 3)) {   // CLEAR/SET_FEATURE
    // uvcvideo clears the bulk endpoint halt when streaming stops.
    if (h.requesttype == 0x02 && h.request == 1 && (h.index & 0xff) == kEpVideo) { [_pending removeAllObjects]; _frame = nil; }
    [self reply:pid header:h status:ST_SUCCESS data:nil];
    return;
  }
  uint8_t iface = h.index & 0xff, entity = h.index >> 8, selector = h.value >> 8;
  BOOL streamingControl = (h.requesttype == 0xA1 || h.requesttype == 0x21) && iface == 1 && entity == 0 && (selector == 1 || selector == 2);
  if (!streamingControl) { [self reply:pid header:h status:ST_STALL data:nil]; return; }
  uint8_t *cur = selector == 1 ? _probe : _commit, tmp[kProbeLen];
  switch (h.request) {
    case 0x01:                                               // SET_CUR
      FillProbe(tmp, len > 3 ? data[3] : 1);
      memcpy(cur, tmp, kProbeLen);
      if (selector == 2) {
        _targetW = kFrames[_commit[3] - 1].w; _targetH = kFrames[_commit[3] - 1].h;
        NSLog(@"webcam: guest selected %dx%d", _targetW, _targetH);
      }
      [self reply:pid header:h status:ST_SUCCESS data:nil];
      return;
    case 0x81: [self reply:pid header:h status:ST_SUCCESS data:[NSData dataWithBytes:cur length:kProbeLen]]; return;
    case 0x82: case 0x83: case 0x87:                          // GET_MIN / GET_MAX / GET_DEF
      FillProbe(tmp, cur[3]);
      [self reply:pid header:h status:ST_SUCCESS data:[NSData dataWithBytes:tmp length:kProbeLen]];
      return;
    case 0x84: memset(tmp, 0, kProbeLen); [self reply:pid header:h status:ST_SUCCESS data:[NSData dataWithBytes:tmp length:kProbeLen]]; return;
    case 0x85: { uint8_t l[2] = {kProbeLen, 0}; [self reply:pid header:h status:ST_SUCCESS data:[NSData dataWithBytes:l length:2]]; return; }
    case 0x86: { uint8_t i = 3; [self reply:pid header:h status:ST_SUCCESS data:[NSData dataWithBytes:&i length:1]]; return; }
  }
  [self reply:pid header:h status:ST_STALL data:nil];
}

// Hand frame bytes to waiting bulk requests. Each frame is one UVC payload: a 2-byte header
// (end-of-header, end-of-frame, frame id) then the JPEG. A short transfer ends the payload; if a
// frame exactly fills its last transfer, a zero-length one follows.
- (void)serve {
  while (_pending.count) {
    if (!_frame && !_needZeroLength) {
      if (!_nextFrame) return;
      _fid = !_fid;
      uint8_t header[2] = {2, 0x80 | 0x02 | (_fid ? 1 : 0)};
      NSMutableData *f = [NSMutableData dataWithBytes:header length:2];
      [f appendData:_nextFrame];
      _frame = f; _nextFrame = nil; _frameOffset = 0;
      if (Debug() && (++_framesSent % 30) == 1)
        NSLog(@"webcam: frame %lu, %lu bytes, %lu requests waiting", (unsigned long)_framesSent, (unsigned long)f.length, (unsigned long)_pending.count);
    }
    NSArray<NSNumber *> *req = _pending.firstObject; [_pending removeObjectAtIndex:0];
    uint64_t pid = req[0].unsignedLongLongValue; NSUInteger want = req[1].unsignedIntegerValue;
    NSData *chunk = nil;
    if (_needZeroLength) { _needZeroLength = NO; }
    else {
      NSUInteger n = MIN(want, _frame.length - _frameOffset);
      chunk = [_frame subdataWithRange:NSMakeRange(_frameOffset, n)];
      _frameOffset += n;
      if (_frameOffset == _frame.length) { _needZeroLength = (n == want); _frame = nil; }
    }
    [self sendBulk:pid endpoint:kEpVideo status:ST_SUCCESS data:chunk];
  }
}

// --- Mac camera -----------------------------------------------------------------------------
- (void)startCapture {
  if (_capturing) return;
  _capturing = YES;
  if (!_targetW) { _targetW = kFrames[_commit[3] - 1].w; _targetH = kFrames[_commit[3] - 1].h; }
  void (^begin)(void) = ^{
    dispatch_async(self->_captureQueue, ^{
      if (self->_session) return;
      AVCaptureDevice *dev = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
      AVCaptureDeviceInput *input = dev ? [AVCaptureDeviceInput deviceInputWithDevice:dev error:nil] : nil;
      if (!input) { NSLog(@"webcam: no Mac camera available"); return; }
      AVCaptureSession *s = [AVCaptureSession new];
      [s beginConfiguration];
      s.sessionPreset = [s canSetSessionPreset:AVCaptureSessionPreset1920x1080] ? AVCaptureSessionPreset1920x1080 : AVCaptureSessionPresetHigh;
      if ([s canAddInput:input]) [s addInput:input];
      AVCaptureVideoDataOutput *out = [AVCaptureVideoDataOutput new];
      out.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
      out.alwaysDiscardsLateVideoFrames = YES;
      [out setSampleBufferDelegate:self queue:self->_captureQueue];
      if ([s canAddOutput:out]) [s addOutput:out];
      [s commitConfiguration];
      [s startRunning];
      self->_session = s;
      NSLog(@"webcam: Mac camera on (%@)", dev.localizedName);
    });
  };
  AVAuthorizationStatus access = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
  if (access == AVAuthorizationStatusAuthorized) begin();
  else if (access == AVAuthorizationStatusNotDetermined)
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) { if (granted) begin(); }];
  else NSLog(@"webcam: camera access denied (System Settings > Privacy & Security > Camera)");
}

- (void)stopCapture {
  if (!_capturing) return;
  _capturing = NO;
  dispatch_async(_captureQueue, ^{
    if (!self->_session) return;
    [self->_session stopRunning]; self->_session = nil;
    NSLog(@"webcam: Mac camera off");
  });
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sample fromConnection:(AVCaptureConnection *)connection {
  CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sample);
  int W = _targetW, H = _targetH;
  if (!pb || W <= 0 || H <= 0) return;
  // Scale to cover the requested size, then crop the centre (16:9 camera into a 4:3 frame, say).
  CIImage *img = [CIImage imageWithCVPixelBuffer:pb];
  CGFloat iw = img.extent.size.width, ih = img.extent.size.height, s = MAX(W / iw, H / ih);
  img = [img imageByApplyingTransform:CGAffineTransformMakeScale(s, s)];
  CGFloat x = round((iw * s - W) / 2), y = round((ih * s - H) / 2);
  img = [[img imageByCroppingToRect:CGRectMake(x, y, W, H)] imageByApplyingTransform:CGAffineTransformMakeTranslation(-x, -y)];
  NSData *jpeg = [_ci JPEGRepresentationOfImage:img colorSpace:_srgb
                                         options:@{(id)kCGImageDestinationLossyCompressionQuality: @0.8}];
  if (!jpeg) return;
  dispatch_async(_q, ^{
    if (!self->_capturing) return;
    self->_nextFrame = jpeg;   // only the newest frame is kept
    [self serve];
  });
}
@end
