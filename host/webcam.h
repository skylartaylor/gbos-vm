// A USB webcam for the guest, backed by the Mac's own camera.
// Speaks QEMU's usb-redir protocol on a Unix socket (see run/run_vm.py --webcam) and presents
// a UVC 1.1 MJPEG camera with a bulk video endpoint. The Mac camera only runs while Android
// is actually streaming from it.
#import <Foundation/Foundation.h>

@interface GBWebcam : NSObject
- (instancetype)initWithSocketPath:(NSString *)path;
// Connects (retrying until the socket exists) and plugs the camera in. Safe to call once.
- (void)start;
- (void)stop;
@end
