#import <AppKit/AppKit.h>
#import <MetalKit/MetalKit.h>
#import "CocoaSpice.h"
#import "CSDisplay+Protected.h"
#import "CSMetalRenderer.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>

static unsigned short scan[128] = {
 [0]=0x1e,[1]=0x1f,[2]=0x20,[3]=0x21,[4]=0x23,[5]=0x22,[6]=0x2c,[7]=0x2d,[8]=0x2e,[9]=0x2f,[11]=0x30,
 [12]=0x10,[13]=0x11,[14]=0x12,[15]=0x13,[16]=0x15,[17]=0x14,[18]=2,[19]=3,[20]=4,[21]=5,[22]=7,[23]=6,
 [24]=0x0d,[25]=0x0a,[26]=8,[27]=0x0c,[28]=9,[29]=0x0b,[30]=0x1b,[31]=0x18,[32]=0x16,[33]=0x1a,[34]=0x17,[35]=0x19,
 [36]=0x1c,[37]=0x26,[38]=0x24,[39]=0x28,[40]=0x25,[41]=0x27,[42]=0x2b,[43]=0x33,[44]=0x35,[45]=0x31,[46]=0x32,[47]=0x34,
 [48]=0x0f,[49]=0x39,[50]=0x29,[51]=0x0e,[53]=1,[55]=0x15b,[54]=0x15c,[56]=0x2a,[60]=0x36,[58]=0x38,[61]=0x138,[59]=0x1d,[62]=0x11d,
 [65]=0x53,[67]=0x37,[69]=0x4e,[75]=0x135,[76]=0x11c,[78]=0x4a,[82]=0x52,[83]=0x4f,[84]=0x50,[85]=0x51,[86]=0x4b,[87]=0x4c,[88]=0x4d,[89]=0x47,[91]=0x48,[92]=0x49,
 [96]=0x3f,[97]=0x40,[98]=0x41,[99]=0x3d,[100]=0x42,[101]=0x43,[103]=0x57,[109]=0x44,[111]=0x58,[115]=0x147,[116]=0x149,[117]=0x153,[118]=0x3e,[119]=0x14f,[120]=0x3c,[121]=0x151,[122]=0x3b,[123]=0x14b,[124]=0x14d,[125]=0x150,[126]=0x148
};
@interface VMView : MTKView
- (void)setHostCursorHidden:(BOOL)hidden;
@property(nonatomic,strong) CSInput *input;
@property(nonatomic) BOOL captured;
@property(nonatomic) BOOL seamless;
@property(nonatomic) BOOL inside;
@property(nonatomic) BOOL cursorHidden;
@property(nonatomic) CSInputButton buttons;
@property(nonatomic) CGSize guestSize;
@property(nonatomic) CGFloat gain;      // guest pixels moved per relative mouse count
@property(nonatomic) CGPoint believed;  // where we believe the guest cursor is, in guest pixels
@property(nonatomic,strong) NSTrackingArea *tracking;
@property(nonatomic) BOOL everSynced;
@property(nonatomic) BOOL haveTarget;
@property(nonatomic) CGPoint target;
@property(nonatomic) NSTimeInterval syncReady;
// Absolute mode: a helper inside Android injects pointer events at exact guest
// coordinates, so the Mac cursor is the pointer and nothing needs steering.
@property(nonatomic) BOOL absolute;
@property(nonatomic) BOOL guestCursor; // Android draws the pointer itself (tablet mode)
// NO while waiting for the helper: moving the emulated USB mouse at all leaves a second,
// frozen Android cursor on screen once the helper takes over.
@property(nonatomic) BOOL relativeAllowed;
@property(nonatomic,copy) void (^sendLine)(NSString *);
- (void)steerToTarget;
- (void)releaseCapture;
- (void)resync;
@end
@implementation VMView
- (BOOL)acceptsFirstResponder{return YES;}
- (BOOL)acceptsFirstMouse:(NSEvent *)event{return YES;}
- (void)updateTrackingAreas {
 [super updateTrackingAreas];
 if(self.tracking)[self removeTrackingArea:self.tracking];
 self.tracking=[[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited|NSTrackingMouseMoved|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect owner:self userInfo:nil];
 [self addTrackingArea:self.tracking];
}
- (void)setHostCursorHidden:(BOOL)hidden {
 if(hidden==self.cursorHidden)return;
 self.cursorHidden=hidden;if(hidden)[NSCursor hide];else [NSCursor unhide];
}
// Seamless pointer: the guest only accepts a relative mouse, so pin its cursor
// to the top-left corner once, then steer it to wherever the Mac pointer is.
- (CGPoint)guestPoint:(NSEvent *)e {
 CGPoint p=[self convertPoint:e.locationInWindow fromView:nil];CGSize b=self.bounds.size,g=self.guestSize;
 CGFloat s=MIN(b.width/g.width,b.height/g.height);if(s<=0)s=1;
 CGFloat x=(p.x-(b.width-g.width*s)/2)/s,y=(b.height-p.y-(b.height-g.height*s)/2)/s;
 return CGPointMake(MAX(0,MIN(g.width-1,x)),MAX(0,MIN(g.height-1,y)));
}
// QEMU sums queued relative motion, so the corner pin must drain (about half a
// second) before any further steering is sent, or the two would cancel out.
- (void)resync {
 if(!self.input||!self.guestSize.width)return;
 [self.input sendMouseMotion:self.buttons relativePoint:CGPointMake(-ceil(self.guestSize.width/self.gain)-400,-ceil(self.guestSize.height/self.gain)-400)];
 self.believed=CGPointZero;self.everSynced=YES;
 self.syncReady=[NSDate timeIntervalSinceReferenceDate]+0.7;
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.72*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[self steerToTarget];});
}
- (void)steerToTarget {
 if(!self.input||!self.guestSize.width||!self.haveTarget)return;
 if([NSDate timeIntervalSinceReferenceDate]<self.syncReady)return;
 CGPoint t=self.target;
 CGFloat ix=round((t.x-self.believed.x)/self.gain),iy=round((t.y-self.believed.y)/self.gain);
 if(ix==0&&iy==0)return;
 [self.input sendMouseMotion:self.buttons relativePoint:CGPointMake(ix,iy)];
 self.believed=CGPointMake(MAX(0,MIN(self.guestSize.width-1,self.believed.x+ix*self.gain)),MAX(0,MIN(self.guestSize.height-1,self.believed.y+iy*self.gain)));
}
- (void)steer:(NSEvent *)e {self.target=[self guestPoint:e];self.haveTarget=YES;[self steerToTarget];}
- (void)mouseEntered:(NSEvent *)e {if(self.absolute){self.inside=YES;if(self.guestCursor)[self setHostCursorHidden:YES];return;}if(!self.seamless)return;self.inside=YES;[self setHostCursorHidden:YES];self.target=[self guestPoint:e];self.haveTarget=YES;if(!self.everSynced)[self resync];else [self steerToTarget];}
- (void)mouseExited:(NSEvent *)e {if(self.absolute){self.inside=NO;[self setHostCursorHidden:NO];self.sendLine(@"X");return;}if(!self.seamless)return;self.inside=NO;[self setHostCursorHidden:NO];}
- (void)capture {
 if(self.seamless||!self.relativeAllowed)return;
 if(!self.captured && self.input){self.captured=YES;[self.window makeFirstResponder:self];[self.input requestMouseMode:YES];CGAssociateMouseAndMouseCursorPosition(false);[NSCursor hide];self.window.subtitle=@"Mouse captured • ⌃⌥ releases";}
}
- (void)releaseCapture {
 [self.input releaseKeys];
 for(NSNumber *b in @[@(kCSInputButtonLeft),@(kCSInputButtonRight),@(kCSInputButtonMiddle)]) [self.input sendMouseButton:b.unsignedIntegerValue mask:0 pressed:NO];
 self.buttons=0;
 if(self.seamless){self.inside=NO;[self setHostCursorHidden:NO];return;}
 if(self.captured){self.captured=NO;CGAssociateMouseAndMouseCursorPosition(true);[NSCursor unhide];self.window.subtitle=@"Click to capture • ⌃⌥ releases";}
}
- (BOOL)live {return self.absolute||(self.seamless?(self.input!=nil):self.captured);}
- (void)button:(CSInputButton)b down:(BOOL)down event:(NSEvent *)e {
 if(self.absolute){
  [self.window makeFirstResponder:self];CGPoint g=[self guestPoint:e];
  int code=b==kCSInputButtonLeft?1:(b==kCSInputButtonRight?2:4);
  self.sendLine([NSString stringWithFormat:@"M %.1f %.1f",g.x,g.y]);self.sendLine([NSString stringWithFormat:@"%c %d",down?'D':'U',code]);return;
 }
 if(!self.seamless&&!self.captured){if(down)[self capture];return;}
 if(self.seamless){[self.window makeFirstResponder:self];if(!self.inside){self.inside=YES;[self setHostCursorHidden:YES];}if(!self.everSynced)[self resync];[self steer:e];}
 if(down)self.buttons|=b;else self.buttons&=~b;
 [self.input sendMouseButton:b mask:self.buttons pressed:down];
}
- (void)mouseDown:(NSEvent *)e {[self button:kCSInputButtonLeft down:YES event:e];}
- (void)mouseUp:(NSEvent *)e {if([self live])[self button:kCSInputButtonLeft down:NO event:e];}
- (void)rightMouseDown:(NSEvent *)e {[self button:kCSInputButtonRight down:YES event:e];}
- (void)rightMouseUp:(NSEvent *)e {if([self live])[self button:kCSInputButtonRight down:NO event:e];}
- (void)otherMouseDown:(NSEvent *)e {[self button:kCSInputButtonMiddle down:YES event:e];}
- (void)otherMouseUp:(NSEvent *)e {if([self live])[self button:kCSInputButtonMiddle down:NO event:e];}
- (void)mouseMoved:(NSEvent *)e {
 if(self.absolute){
  // Mouse-moved events also arrive over the title bar; only own the cursor inside the view.
  if(!NSPointInRect([self convertPoint:e.locationInWindow fromView:nil],self.bounds)){if(self.inside){self.inside=NO;[self setHostCursorHidden:NO];self.sendLine(@"X");}return;}
  self.inside=YES;if(self.guestCursor)[self setHostCursorHidden:YES];CGPoint g=[self guestPoint:e];self.sendLine([NSString stringWithFormat:@"M %.1f %.1f",g.x,g.y]);return;}
 if(self.seamless){if(self.inside)[self steer:e];return;}
 if(!self.captured)return;CGFloat scale=MIN(self.bounds.size.width/self.guestSize.width,self.bounds.size.height/self.guestSize.height);if(scale<=0)scale=1;[self.input sendMouseMotion:self.buttons relativePoint:CGPointMake(e.deltaX/scale,e.deltaY/scale)];
}
- (void)mouseDragged:(NSEvent *)e {[self mouseMoved:e];}
- (void)rightMouseDragged:(NSEvent *)e {[self mouseMoved:e];}
- (void)otherMouseDragged:(NSEvent *)e {[self mouseMoved:e];}
- (void)scrollWheel:(NSEvent *)e {
 if(self.absolute){CGFloat k=e.hasPreciseScrollingDeltas?1.0/16:1.0;if(e.scrollingDeltaX||e.scrollingDeltaY)self.sendLine([NSString stringWithFormat:@"S %.3f %.3f",-e.scrollingDeltaX*k,e.scrollingDeltaY*k]);return;}
 if([self live])[self.input sendMouseScroll:kCSInputScrollSmooth buttonMask:self.buttons dy:-e.scrollingDeltaY/10.0];}
- (void)keyDown:(NSEvent *)e {if([self live] && e.keyCode<128 && scan[e.keyCode])[self.input sendKey:kCSInputKeyPress code:scan[e.keyCode]];}
- (void)keyUp:(NSEvent *)e {if([self live] && e.keyCode<128 && scan[e.keyCode])[self.input sendKey:kCSInputKeyRelease code:scan[e.keyCode]];}
- (void)flagsChanged:(NSEvent *)e {
 // Control+Option releases a captured mouse (the same chord UTM uses), so Esc reaches the guest.
 if(self.captured&&(e.modifierFlags&NSEventModifierFlagControl)&&(e.modifierFlags&NSEventModifierFlagOption)){[self releaseCapture];return;}
 if(![self live])return;NSUInteger flag=0;switch(e.keyCode){case 56:case 60:flag=NSEventModifierFlagShift;break;case 59:case 62:flag=NSEventModifierFlagControl;break;case 58:case 61:flag=NSEventModifierFlagOption;break;case 54:case 55:flag=NSEventModifierFlagCommand;break;}if(flag)[self.input sendKey:(e.modifierFlags&flag)?kCSInputKeyPress:kCSInputKeyRelease code:scan[e.keyCode]];}
@end

@interface App : NSObject<NSApplicationDelegate,NSWindowDelegate,CSConnectionDelegate>
@property(nonatomic,strong) NSWindow *window;
@property(nonatomic,strong) VMView *view;
@property(nonatomic,strong) CSMetalRenderer *renderer;
@property(nonatomic,strong) CSConnection *connection;
@property(nonatomic,strong) CSDisplay *display;
@property(nonatomic,strong) NSString *socketPath;
@property(nonatomic) BOOL startFullscreen;
@property(nonatomic,strong) NSWindow *settingsWindow;
@property(nonatomic,strong) NSTask *vmTask;
@property(nonatomic,strong) NSTask *batteryTask;
@property(nonatomic,strong) NSString *runDir;
@property(nonatomic) BOOL quitting;
@property(nonatomic) BOOL restarting;
@property(nonatomic) BOOL densitySent;
@property(nonatomic) NSInteger guestDensity;
@property(nonatomic,strong) NSPopUpButton *pointerPopup;
- (void)syncSettingsWindow;
@property(nonatomic,strong) dispatch_source_t selftest;
@property(nonatomic,strong) dispatch_source_t selftest2;
@property(nonatomic,strong) dispatch_source_t acceptSource;
@property(nonatomic,strong) dispatch_source_t readSource;
@property(nonatomic) int ctlFd;
@property(nonatomic,strong) NSMutableData *ctlBuffer;
@property(nonatomic) NSInteger sentClipCount;
@end
@implementation App
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
 [[NSUserDefaults standardUserDefaults] registerDefaults:@{@"PointerMode":@2,@"Resolution":@"native",@"StartFullscreen":@NO,@"MemoryMiB":@4096,@"CPUs":@6,@"Networking":@YES,@"Audio":@YES}];
 self.window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,1280,800) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
 self.window.title=@"Googlebook VM";self.window.subtitle=@"Connecting…";self.window.delegate=self;self.window.acceptsMouseMovedEvents=YES;self.window.collectionBehavior=NSWindowCollectionBehaviorFullScreenPrimary;
 self.view=[[VMView alloc] initWithFrame:self.window.contentView.bounds device:MTLCreateSystemDefaultDevice()];self.view.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;self.view.preferredFramesPerSecond=120;self.view.clearColor=MTLClearColorMake(0,0,0,1);
 // Started from the Dock or Finder (no socket argument): this app runs the VM itself.
 if(!self.socketPath){setenv("VM_MOUSE_SEAMLESS","0",1);setenv("VM_MOUSE_RELATIVE","0",1);self.startFullscreen=[[NSUserDefaults standardUserDefaults] boolForKey:@"StartFullscreen"];}
 const char *sm=getenv("VM_MOUSE_SEAMLESS"),*gn=getenv("VM_MOUSE_GAIN");self.view.seamless=!(sm&&!strcmp(sm,"0"));
 const char *rl=getenv("VM_MOUSE_RELATIVE");self.view.relativeAllowed=!(rl&&!strcmp(rl,"0"))||[self pointerMode]==2;
 if(!self.view.relativeAllowed)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(150*NSEC_PER_SEC)),dispatch_get_main_queue(),^{if(!self.view.absolute){self.view.relativeAllowed=YES;[self updateSubtitle];}});self.view.gain=(gn&&atof(gn)>0)?atof(gn):0.75;
 self.renderer=[[CSMetalRenderer alloc] initWithMetalKitView:self.view];self.view.delegate=self.renderer;
 self.window.contentView=self.view;[self.window center];[self.window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
 if(self.startFullscreen)[self.window toggleFullScreen:nil];
 __weak App *weakSelf=self;self.view.sendLine=^(NSString *l){[weakSelf ctlSend:l];};[self startControlServer];
 [CSMain.sharedInstance spiceSetDebug:NO];
 if(![CSMain.sharedInstance spiceStart]){fprintf(stderr,"SPICE worker failed\n");[NSApp terminate:nil];return;}
 if(self.socketPath)[self connectSpice];else [self startVM];
 [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer){[self fit];}];
 // Self-test hook: SIGUSR1 steers the guest cursor to the centre of its screen.
 signal(SIGUSR1,SIG_IGN);dispatch_source_t usr=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,SIGUSR1,0,dispatch_get_main_queue());
 dispatch_source_set_event_handler(usr,^{CGSize g=self.view.guestSize;const char *pt=getenv("VM_SELFTEST_POINT");double fx=.5,fy=.5;if(pt)sscanf(pt,"%lf,%lf",&fx,&fy);
  if(self.view.absolute){[self ctlSend:[NSString stringWithFormat:@"M %.1f %.1f",g.width*fx,g.height*fy]];[self ctlSend:@"D 1"];dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(5*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[self ctlSend:@"U 1"];});fprintf(stderr,"SELFTEST absolute %.1f %.1f\n",g.width*fx,g.height*fy);return;}self.view.target=CGPointMake(g.width*fx,g.height*fy);self.view.haveTarget=YES;[self.view resync];
  // Click once at the target so Android's pointer-location overlay reports where the cursor really is.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2.2*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[self.view.input sendMouseButton:kCSInputButtonLeft mask:kCSInputButtonLeft pressed:YES];});
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(6.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[self.view.input sendMouseButton:kCSInputButtonLeft mask:0 pressed:NO];});fprintf(stderr,"SELFTEST centre gain=%.3f guest=%.0fx%.0f\n",self.view.gain,g.width,g.height);});
 dispatch_resume(usr);self.selftest=usr;
 // Self-test hook: SIGUSR2 sends a burst of scroll events at the current pointer position.
 signal(SIGUSR2,SIG_IGN);dispatch_source_t usr2=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,SIGUSR2,0,dispatch_get_main_queue());
 dispatch_source_set_event_handler(usr2,^{for(int i=0;i<8;i++)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(i*0.05*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[self ctlSend:@"S 0.000 -0.500"];});fprintf(stderr,"SELFTEST scroll\n");});
 dispatch_resume(usr2);self.selftest2=usr2;
 fprintf(stderr,"WINDOW %ld\n",(long)self.window.windowNumber);
 fprintf(stderr,"NATIVE_VIEWER device=%s target_hz=60 socket=%s\n",self.view.device.name.UTF8String,self.socketPath.UTF8String);
}
- (void)fit {CGSize size=self.display.displaySize;if(size.width && size.height){if(!CGSizeEqualToSize(size,self.view.guestSize)){self.view.guestSize=size;[self sendGeometry];}self.view.guestSize=size;self.renderer.viewportScale=MIN(self.view.drawableSize.width/size.width,self.view.drawableSize.height/size.height);self.renderer.viewportOrigin=CGPointZero;self.window.title=[NSString stringWithFormat:@"Googlebook • %.0f×%.0f • %@",size.width,size.height,self.display.isGLEnabled?@"Metal / IOSurface":@"SPICE"];}}
- (void)windowDidResize:(NSNotification *)n{[self fit];}
- (void)resyncPointer:(id)sender{[self.view resync];}
- (void)toggleFull:(id)sender{[self.window toggleFullScreen:nil];}
- (void)connectSpice {
 self.connection=[[CSConnection alloc] initWithUnixSocketFile:[NSURL fileURLWithPath:self.socketPath]];self.connection.audioEnabled=NO;self.connection.session.shareClipboard=NO;self.connection.delegate=self;
 [self.connection connect];
}
- (void)fail:(NSString *)message {
 NSAlert *a=[NSAlert new];a.messageText=@"Googlebook VM couldn't start";a.informativeText=message;[a runModal];self.vmTask=nil;[NSApp terminate:nil];
}
// Self-starting mode: run the VM with the bundled runner script, wait for its display socket,
// then connect. Quitting asks the runner to stop, which powers Android off cleanly first.
- (void)startVM {
 NSBundle *b=NSBundle.mainBundle;NSUserDefaults *d=[NSUserDefaults standardUserDefaults];
 const char *e=getenv("GOOGLEBOOK_WORK");NSString *work=e?@(e):[b objectForInfoDictionaryKey:@"GBOSWork"];
 NSString *runner=[b pathForResource:@"run_vm" ofType:@"py"];
 // Prefer the folder this app sits in (WORK/host/Googlebook VM.app), so a work folder that was
 // moved or copied to another Mac keeps working; fall back to the path recorded at build time
 // for an app that was copied out on its own (to /Applications, say).
 NSString *beside=[[b.bundlePath stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
 if(!e&&[[NSFileManager defaultManager] fileExistsAtPath:[beside stringByAppendingPathComponent:@"image/googlebook.raw"]])work=beside;
 if(!work||!runner||![[NSFileManager defaultManager] fileExistsAtPath:[work stringByAppendingPathComponent:@"image/googlebook.raw"]]){
  [self fail:[NSString stringWithFormat:@"No VM image at %@/image. Run install.sh first, or rebuild the app if you moved the folder.",work?:@"(unknown)"]];return;}
 NSString *res=[[d objectForKey:@"Resolution"] description];
 if(![res containsString:@"x"]){
  // "Match this Mac's display": the panel's native pixels, not the (possibly larger) scaled
  // backing size macOS renders at. 16:10 height, which is the area below a MacBook notch.
  NSScreen *sc=NSScreen.mainScreen;CGFloat w=sc.frame.size.width*sc.backingScaleFactor,h=sc.frame.size.height*sc.backingScaleFactor;
  CGDirectDisplayID did=[sc.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
  NSArray *modes=CFBridgingRelease(CGDisplayCopyAllDisplayModes(did,(__bridge CFDictionaryRef)@{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes:@YES}));
  for(id m in modes){CGDisplayModeRef mode=(__bridge CGDisplayModeRef)m;
   if(CGDisplayModeGetIOFlags(mode)&0x02000000 /* kDisplayModeNativeFlag */){w=CGDisplayModeGetPixelWidth(mode);h=CGDisplayModeGetPixelHeight(mode);break;}}
  res=[NSString stringWithFormat:@"%.0fx%.0f",w,MIN(h,round(w/1.6))];}
 self.guestDensity=(NSInteger)round(240.0*[res integerValue]/1920.0);
 NSDateFormatter *f=[NSDateFormatter new];f.dateFormat=@"yyyyMMdd-HHmmss";NSString *name=[@"desktop-" stringByAppendingString:[f stringFromDate:[NSDate date]]];
 self.runDir=[[work stringByAppendingPathComponent:@"logs"] stringByAppendingPathComponent:name];
 NSMutableArray *args=[@[runner,work,name,@"--display",res,@"--memory",[[d objectForKey:@"MemoryMiB"] description],@"--cpus",[[d objectForKey:@"CPUs"] description]] mutableCopy];
 if(![d boolForKey:@"Networking"])[args addObject:@"--offline"];
 if(![d boolForKey:@"Audio"])[args addObject:@"--no-audio"];
 NSTask *t=[NSTask new];t.executableURL=[NSURL fileURLWithPath:@"/usr/bin/python3"];t.arguments=args;
 t.standardOutput=[NSFileHandle fileHandleWithNullDevice];t.standardError=[NSFileHandle fileHandleWithNullDevice];
 __weak App *weak=self;
 t.terminationHandler=^(NSTask *x){dispatch_async(dispatch_get_main_queue(),^{
  App *me=weak;if(!me||me.vmTask!=x)return;me.vmTask=nil;
  if(me.quitting){
   // Restart: once Android is down and the runner has exited, open a fresh copy of the app.
   // A new instance also picks up any Settings that only apply at start.
   if(me.restarting){NSTask *o=[NSTask new];o.executableURL=[NSURL fileURLWithPath:@"/bin/sh"];o.arguments=@[@"-c",@"sleep 1; exec /usr/bin/open -n \"$0\"",NSBundle.mainBundle.bundlePath];[o launchAndReturnError:nil];}
   [NSApp replyToApplicationShouldTerminate:YES];
  }
  else if(me.connection)[NSApp terminate:nil];   // Android shut itself down
  else [me fail:@"The VM exited before its display came up. Another Googlebook VM may already be running; otherwise check the newest folder under logs/."];
 });};
 NSError *err=nil;if(![t launchAndReturnError:&err]){[self fail:err.localizedDescription];return;}
 self.vmTask=t;self.window.subtitle=@"Starting the VM…";
 [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer){
  if(!self.vmTask){[timer invalidate];return;}
  NSFileManager *fm=[NSFileManager defaultManager];
  if(!self.connection){
   if(![fm fileExistsAtPath:[self.runDir stringByAppendingPathComponent:@"spice.sock"]])return;
   NSString *tk=[NSString stringWithContentsOfFile:[self.runDir stringByAppendingPathComponent:@"token"] encoding:NSUTF8StringEncoding error:nil];
   if(tk.length)setenv("VM_INPUT_TOKEN",tk.UTF8String,1);
   self.socketPath=[self.runDir stringByAppendingPathComponent:@"spice.sock"];[self connectSpice];return;
  }
  if(self.densitySent){[timer invalidate];return;}
  // Once Android is up, match the display density to the resolution (the setting persists).
  NSData *log=[NSData dataWithContentsOfFile:[self.runDir stringByAppendingPathComponent:@"serial.log"]];
  if(log&&[log rangeOfData:[@"VM_BOOT_COMPLETED" dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(0,log.length)].location!=NSNotFound){
   self.densitySent=YES;
   dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(8*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
    NSTask *c=[NSTask new];c.executableURL=[NSURL fileURLWithPath:@"/usr/bin/python3"];
    c.arguments=@[[NSBundle.mainBundle pathForResource:@"vm_control" ofType:@"py"],self.runDir,[NSString stringWithFormat:@"VM_DENSITY %ld",(long)self.guestDensity]];
    [c launchAndReturnError:nil];});
   dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(9*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
    NSString *bs=[NSBundle.mainBundle pathForResource:@"battery_sync" ofType:@"py"];
    if(bs){
     self.batteryTask=[NSTask new];self.batteryTask.executableURL=[NSURL fileURLWithPath:@"/usr/bin/python3"];
     self.batteryTask.arguments=@[bs,self.runDir];
     [self.batteryTask launchAndReturnError:nil];
    }
   });
  }
 }];
}
- (void)restartVM:(id)sender {if(self.vmTask){self.restarting=YES;[NSApp terminate:nil];}}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
 if(self.batteryTask&&self.batteryTask.running)[self.batteryTask terminate];
 if(!self.vmTask||!self.vmTask.running)return NSTerminateNow;
 self.quitting=YES;self.window.subtitle=self.restarting?@"Restarting: shutting Android down…":@"Shutting Android down…";[self.view releaseCapture];[self.vmTask terminate];
 return NSTerminateLater;
}
// Control link to the helper inside Android (scripts/guest_input): it connects
// to this loopback port through the VM's NAT and takes pointer/clipboard lines.
- (void)ctlSend:(NSString *)line {
 if(self.ctlFd<0)return;
 NSData *d=[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
 if(write(self.ctlFd,d.bytes,d.length)!=(ssize_t)d.length)[self ctlClose];
}
- (void)ctlClose {
 if(self.readSource){dispatch_source_cancel(self.readSource);self.readSource=nil;}
 if(self.ctlFd>=0){close(self.ctlFd);self.ctlFd=-1;}
 self.view.absolute=NO;self.view.guestCursor=NO;[self.view setHostCursorHidden:NO];fprintf(stderr,"CONTROL disconnected\n");[self updateSubtitle];
}
- (void)updateSubtitle {
 NSInteger mode=[self pointerMode];
 if(mode==2&&self.view.relativeAllowed)self.window.subtitle=@"Captured mouse: click to capture, ⌃⌥ releases • ⌃⌘M switches pointer mode";
 else if(self.view.absolute)self.window.subtitle=self.view.guestCursor?@"Android cursor • ⌃⌘M switches pointer mode • ⌃⌘F full screen":@"Mac cursor • ⌃⌘M switches pointer mode • ⌃⌘F full screen";
 else self.window.subtitle=self.view.relativeAllowed?@"Click to capture • ⌃⌥ releases":@"Waiting for Android to link the pointer…";
}
// Pointer modes, cycled with Ctrl+Cmd+M and remembered:
//   (2, the captured mouse, is the default; 0 and 1 are labelled experimental in the UI.)
//   0 Android cursor: the helper's tablet device; Android draws the pointer (guest refresh rate).
//   1 Mac cursor:     the helper injects events; the Mac pointer is the cursor (always an arrow).
//   2 Captured mouse: the classic emulated USB mouse; click to capture, Control+Option releases.
- (NSInteger)pointerMode {return [[NSUserDefaults standardUserDefaults] integerForKey:@"PointerMode"]%3;}
- (void)sendGeometry {CGSize g=self.view.guestSize;if(self.ctlFd<0||g.width<=0)return;
 [self ctlSend:[self pointerMode]==0?[NSString stringWithFormat:@"G %.0f %.0f",g.width,g.height]:@"G 0 0"];}
- (void)applyPointerMode {
 NSInteger mode=[self pointerMode];
 [self.view releaseCapture];
 self.view.absolute=self.ctlFd>=0&&mode!=2;
 if(mode==2){self.view.relativeAllowed=YES;self.view.guestCursor=NO;[self.view setHostCursorHidden:NO];}
 [self updateSubtitle];
}
- (void)toggleCursor:(id)sender{NSUserDefaults *d=[NSUserDefaults standardUserDefaults];[d setInteger:([self pointerMode]+1)%3 forKey:@"PointerMode"];[self applyPointerMode];[self sendGeometry];[self syncSettingsWindow];}
- (void)choosePointerMode:(NSMenuItem *)sender{[[NSUserDefaults standardUserDefaults] setInteger:sender.tag forKey:@"PointerMode"];[self applyPointerMode];[self sendGeometry];[self syncSettingsWindow];}
- (BOOL)validateMenuItem:(NSMenuItem *)item{if(item.action==@selector(restartVM:))return self.vmTask!=nil;if(item.action==@selector(choosePointerMode:))item.state=item.tag==[self pointerMode]?NSControlStateValueOn:NSControlStateValueOff;return YES;}

// Settings window. Pointer mode applies immediately; the rest are read by the launcher the
// next time the VM starts (they are QEMU options), which the window says.
- (NSPopUpButton *)popup:(NSString *)key titles:(NSArray<NSString *> *)titles values:(NSArray *)values {
 NSPopUpButton *b=[NSPopUpButton new];b.identifier=key;b.target=self;b.action=@selector(settingChanged:);
 id current=[[NSUserDefaults standardUserDefaults] objectForKey:key];
 for(NSUInteger i=0;i<titles.count;i++){[b addItemWithTitle:titles[i]];b.lastItem.representedObject=values[i];if([values[i] isEqual:current])[b selectItemAtIndex:i];}
 return b;
}
- (NSButton *)checkbox:(NSString *)key title:(NSString *)title {
 NSButton *b=[NSButton checkboxWithTitle:title target:self action:@selector(checkChanged:)];b.identifier=key;
 b.state=[[NSUserDefaults standardUserDefaults] boolForKey:key]?NSControlStateValueOn:NSControlStateValueOff;return b;
}
- (void)settingChanged:(NSPopUpButton *)sender {
 [[NSUserDefaults standardUserDefaults] setObject:sender.selectedItem.representedObject forKey:sender.identifier];
 if([sender.identifier isEqualToString:@"PointerMode"]){[self applyPointerMode];[self sendGeometry];}
}
- (void)checkChanged:(NSButton *)sender {[[NSUserDefaults standardUserDefaults] setBool:sender.state==NSControlStateValueOn forKey:sender.identifier];}
- (void)syncSettingsWindow {[self.pointerPopup selectItemAtIndex:([self pointerMode]+1)%3];}
- (void)showSettings:(id)sender {
 if(!self.settingsWindow){
  NSTextField *(^label)(NSString *)=^NSTextField *(NSString *t){NSTextField *l=[NSTextField labelWithString:t];l.alignment=NSTextAlignmentRight;return l;};
  self.pointerPopup=[self popup:@"PointerMode" titles:@[@"Captured mouse",@"Android cursor (experimental)",@"Mac cursor (experimental)"] values:@[@2,@0,@1]];
  NSTextField *hint=[NSTextField labelWithString:@"Captured mouse: click to grab, ⌃⌥ to release. ⌃⌘M cycles modes."];hint.textColor=NSColor.secondaryLabelColor;hint.font=[NSFont systemFontOfSize:NSFont.smallSystemFontSize];
  NSTextField *note=[NSTextField wrappingLabelWithString:@"Everything below applies the next time you start the VM."];note.textColor=NSColor.secondaryLabelColor;note.font=[NSFont systemFontOfSize:NSFont.smallSystemFontSize];
  NSGridView *grid=[NSGridView gridViewWithViews:@[
   @[label(@"Pointer:"),self.pointerPopup],
   @[[NSGridCell emptyContentView],hint],
   @[[NSGridCell emptyContentView],note],
   @[[NSGridCell emptyContentView],[NSButton buttonWithTitle:@"Restart VM Now" target:self action:@selector(restartVM:)]],
   @[label(@"Resolution:"),[self popup:@"Resolution" titles:@[@"Match this Mac's display",@"1920 × 1200",@"2560 × 1600",@"3024 × 1890",@"3456 × 2160"] values:@[@"native",@"1920x1200",@"2560x1600",@"3024x1890",@"3456x2160"]]],
   @[[NSGridCell emptyContentView],[self checkbox:@"StartFullscreen" title:@"Start in full screen"]],
   @[label(@"Memory:"),[self popup:@"MemoryMiB" titles:@[@"4 GB",@"6 GB",@"8 GB"] values:@[@4096,@6144,@8192]]],
   @[label(@"Processor cores:"),[self popup:@"CPUs" titles:@[@"4",@"6",@"8"] values:@[@4,@6,@8]]],
   @[[NSGridCell emptyContentView],[self checkbox:@"Networking" title:@"Networking (also needed for the pointer and clipboard link)"]],
   @[[NSGridCell emptyContentView],[self checkbox:@"Audio" title:@"Audio output"]]]];
  grid.rowSpacing=8;grid.columnSpacing=10;grid.translatesAutoresizingMaskIntoConstraints=NO;
  [grid columnAtIndex:0].xPlacement=NSGridCellPlacementTrailing;
  NSWindow *w=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,520,370) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
  w.title=@"Googlebook Settings";w.releasedWhenClosed=NO;[w.contentView addSubview:grid];
  [NSLayoutConstraint activateConstraints:@[[grid.topAnchor constraintEqualToAnchor:w.contentView.topAnchor constant:20],[grid.leadingAnchor constraintEqualToAnchor:w.contentView.leadingAnchor constant:20],[grid.trailingAnchor constraintLessThanOrEqualToAnchor:w.contentView.trailingAnchor constant:-20],[grid.bottomAnchor constraintLessThanOrEqualToAnchor:w.contentView.bottomAnchor constant:-20]]];
  [w center];self.settingsWindow=w;
 }
 [self syncSettingsWindow];[self.view releaseCapture];[self.settingsWindow makeKeyAndOrderFront:nil];
}
- (void)pushClipboard {
 if(self.ctlFd<0)return;NSPasteboard *pb=[NSPasteboard generalPasteboard];
 if(pb.changeCount==self.sentClipCount)return;self.sentClipCount=pb.changeCount;
 NSString *t=[pb stringForType:NSPasteboardTypeString];if(!t.length||t.length>100000)return;
 [self ctlSend:[@"C " stringByAppendingString:[[t dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0]]];
}
- (void)ctlLine:(NSString *)line {
 if([line hasPrefix:@"m "]){self.view.guestCursor=[line isEqualToString:@"m tablet"]&&[self pointerMode]==0;if(!self.view.guestCursor||!self.view.inside)[self.view setHostCursorHidden:NO];else [self.view setHostCursorHidden:YES];fprintf(stderr,"CONTROL pointer mode %s\n",line.UTF8String+2);[self updateSubtitle];return;}
 if([line hasPrefix:@"c "]){
  NSData *d=[[NSData alloc] initWithBase64EncodedString:[line substringFromIndex:2] options:0];NSString *t=d?[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]:nil;
  if(t.length){NSPasteboard *pb=[NSPasteboard generalPasteboard];[pb clearContents];[pb setString:t forType:NSPasteboardTypeString];self.sentClipCount=pb.changeCount;}
 }
}
- (void)startControlServer {
 self.ctlFd=-1;signal(SIGPIPE,SIG_IGN);
 const char *pe=getenv("VM_INPUT_PORT");int port=pe?atoi(pe):27183;if(port<=0)return;
 int ls=socket(AF_INET,SOCK_STREAM,0),one=1;setsockopt(ls,SOL_SOCKET,SO_REUSEADDR,&one,sizeof one);
 struct sockaddr_in a={.sin_family=AF_INET,.sin_port=htons(port),.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
 if(bind(ls,(struct sockaddr *)&a,sizeof a)||listen(ls,1)){fprintf(stderr,"CONTROL listen failed on %d\n",port);close(ls);return;}
 self.acceptSource=dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,ls,0,dispatch_get_main_queue());
 dispatch_source_set_event_handler(self.acceptSource,^{
  int fd=accept(ls,NULL,NULL);if(fd<0)return;
  if(self.ctlFd>=0)[self ctlClose];
  int yes=1;setsockopt(fd,IPPROTO_TCP,TCP_NODELAY,&yes,sizeof yes);
  self.ctlFd=fd;self.ctlBuffer=[NSMutableData data];[self applyPointerMode];self.sentClipCount=-1;
  fprintf(stderr,"CONTROL connected\n");[self updateSubtitle];
  const char *tk=getenv("VM_INPUT_TOKEN");if(tk&&*tk)[self ctlSend:[NSString stringWithFormat:@"A %s",tk]];
  [self sendGeometry];[self pushClipboard];
  dispatch_source_t rs=dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,fd,0,dispatch_get_main_queue());self.readSource=rs;
  dispatch_source_set_event_handler(rs,^{
   char buf[65536];ssize_t n=read(fd,buf,sizeof buf);if(n<=0){if(self.ctlFd==fd)[self ctlClose];return;}
   [self.ctlBuffer appendBytes:buf length:n];
   while(1){const char *b=self.ctlBuffer.bytes;const char *nl=memchr(b,'\n',self.ctlBuffer.length);if(!nl)break;
    NSString *line=[[NSString alloc] initWithBytes:b length:nl-b encoding:NSUTF8StringEncoding];
    [self.ctlBuffer replaceBytesInRange:NSMakeRange(0,nl-b+1) withBytes:NULL length:0];if(line)[self ctlLine:line];}
  });
  dispatch_resume(rs);
 });
 dispatch_resume(self.acceptSource);fprintf(stderr,"CONTROL listening on 127.0.0.1:%d\n",port);
}
- (void)applicationDidBecomeActive:(NSNotification *)n{[self pushClipboard];}
// Paste the Mac clipboard's text into the guest as typed input, through the
// VM's fixed-verb control channel. Nothing is ever copied out of the guest.
- (void)pasteIntoGuest:(id)sender{
 if(self.view.absolute){[self pushClipboard];[self ctlSend:@"K 279"];return;}
 NSBeep(); // no helper link yet, so there is nowhere to paste to
}
- (void)windowDidResignKey:(NSNotification *)n{[self.view releaseCapture];}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender{return NO;}
- (void)windowWillClose:(NSNotification *)n{if(n.object==self.window)[NSApp terminate:nil];}
- (void)applicationWillTerminate:(NSNotification *)n{[self.view releaseCapture];[self.connection disconnect];}
- (void)spiceConnected:(CSConnection *)c{fprintf(stderr,"SPICE connected\n");}
- (void)spiceDisconnected:(CSConnection *)c{dispatch_async(dispatch_get_main_queue(),^{[self.view releaseCapture];self.window.subtitle=@"VM disconnected";});}
- (void)spiceInputAvailable:(CSConnection *)c input:(CSInput *)i{dispatch_async(dispatch_get_main_queue(),^{self.view.input=i;[i requestMouseMode:YES];});}
- (void)spiceInputUnavailable:(CSConnection *)c input:(CSInput *)i{dispatch_async(dispatch_get_main_queue(),^{[self.view releaseCapture];self.view.input=nil;});}
- (void)spiceError:(CSConnection *)c code:(CSConnectionError)code message:(NSString *)message{fprintf(stderr,"SPICE error %s\n",message.UTF8String);dispatch_async(dispatch_get_main_queue(),^{self.window.subtitle=message;});}
- (void)spiceDisplayCreated:(CSConnection *)c display:(CSDisplay *)d{dispatch_async(dispatch_get_main_queue(),^{self.display=d;[d addRenderer:self.renderer];[self fit];self.window.subtitle=self.view.seamless?@"⌘V pastes into guest • ⌃⌘F full screen • ⌃⌘R re-syncs pointer":@"Click to capture • ⌃⌥ releases";fprintf(stderr,"DISPLAY created %.0fx%.0f GL=%d\n",d.displaySize.width,d.displaySize.height,d.isGLEnabled);});}
- (void)spiceDisplayUpdated:(CSConnection *)c display:(CSDisplay *)d{dispatch_async(dispatch_get_main_queue(),^{[self fit];});}
- (void)spiceDisplayDestroyed:(CSConnection *)c display:(CSDisplay *)d{dispatch_async(dispatch_get_main_queue(),^{[d removeRenderer:self.renderer];self.display=nil;});}
- (void)spiceAgentConnected:(CSConnection *)c supportingFeatures:(CSConnectionAgentFeature)f{}
- (void)spiceAgentDisconnected:(CSConnection *)c{}
- (void)spiceForwardedPortOpened:(CSConnection *)c port:(CSPort *)p{}
- (void)spiceForwardedPortClosed:(CSConnection *)c port:(CSPort *)p{}
@end
int main(int argc,char **argv){@autoreleasepool {
 if(argc>3){fprintf(stderr,"Usage: GooglebookViewer [/absolute/path/to/spice.sock [--fullscreen]]\n");return 2;}
 NSApplication *app=[NSApplication sharedApplication];[app setActivationPolicy:NSApplicationActivationPolicyRegular];
 // Menu bar. Actions have no target, so they reach the app delegate through the responder chain.
 NSMenu *bar=[NSMenu new];
 NSMenu *(^add)(NSString *)=^NSMenu *(NSString *title){NSMenuItem *it=[bar addItemWithTitle:title action:nil keyEquivalent:@""];NSMenu *m=[[NSMenu alloc] initWithTitle:title];it.submenu=m;return m;};
 NSMenu *appMenu=add(@"Googlebook");
 [appMenu addItemWithTitle:@"Settings…" action:@selector(showSettings:) keyEquivalent:@","];
 [appMenu addItem:[NSMenuItem separatorItem]];
 NSMenuItem *rs=[appMenu addItemWithTitle:@"Restart VM" action:@selector(restartVM:) keyEquivalent:@"r"];rs.keyEquivalentModifierMask=NSEventModifierFlagControl|NSEventModifierFlagCommand;
 [appMenu addItemWithTitle:@"Shut Down and Quit" action:@selector(terminate:) keyEquivalent:@"q"];
 NSMenu *editMenu=add(@"Edit");
 [editMenu addItemWithTitle:@"Paste into Guest" action:@selector(pasteIntoGuest:) keyEquivalent:@"v"];
 NSMenu *viewMenu=add(@"View");
 NSMenuItem *fs=[viewMenu addItemWithTitle:@"Toggle Full Screen" action:@selector(toggleFull:) keyEquivalent:@"f"];fs.keyEquivalentModifierMask=NSEventModifierFlagControl|NSEventModifierFlagCommand;
 NSMenu *pointerMenu=add(@"Pointer");
 // Captured mouse is the default; the two integrated modes still have rough edges.
 NSArray *modes=@[@"Android Cursor (Experimental)",@"Mac Cursor (Experimental)",@"Captured Mouse"];
 for(NSNumber *n in @[@2,@0,@1]){NSMenuItem *it=[pointerMenu addItemWithTitle:modes[n.integerValue] action:@selector(choosePointerMode:) keyEquivalent:@""];it.tag=n.integerValue;}
 [pointerMenu addItem:[NSMenuItem separatorItem]];
 NSMenuItem *next=[pointerMenu addItemWithTitle:@"Next Pointer Mode" action:@selector(toggleCursor:) keyEquivalent:@"m"];next.keyEquivalentModifierMask=NSEventModifierFlagControl|NSEventModifierFlagCommand;
 app.mainMenu=bar;
 App *delegate=[App new];if(argc>=2&&argv[1][0]=='/')delegate.socketPath=[NSString stringWithUTF8String:argv[1]];delegate.startFullscreen=argc==3&&!strcmp(argv[2],"--fullscreen");app.delegate=delegate;[app run];return 0;
}}
