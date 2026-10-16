// A USB microphone for the guest, backed by the Mac's own microphone.
// Speaks QEMU's usb-redir protocol on a Unix socket (see run/run_vm.py --microphone) and presents
// a USB Audio Class 1 microphone (48 kHz, mono, 16-bit) with one isochronous endpoint. The Mac
// microphone only runs while Android is actually recording from it.
#import <Foundation/Foundation.h>

@interface GBMicrophone : NSObject
- (instancetype)initWithSocketPath:(NSString *)path;
// Connects (retrying until the socket exists) and plugs the microphone in. Safe to call once.
- (void)start;
- (void)stop;
@end
