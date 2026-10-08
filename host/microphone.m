// A USB Audio Class 1 microphone for the guest backed by the Mac microphone, over QEMU usb-redir.
// See microphone.h.
//
// Why: QEMU on macOS can't capture sound. Its usb-audio device and its coreaudio backend are both
// playback-only, so the guest has no microphone and anything that records (video in the Camera
// app, calls in Chrome) waits forever. As with host/webcam.m, this process *is* the USB device
// instead: a full-speed UAC1 microphone whose isochronous IN endpoint is fed from AVAudioEngine.
// The guest kernel's snd-usb-audio and Android's USB audio support take it from there, once the
// image gives Android a USB input module and drops the built-in microphone the VM doesn't have
// (image/mica_audio_port.py).
//
// Isochronous data over usb-redir: when the guest starts reading, QEMU sends start_iso_stream.
// From then on the device sends one iso_packet per USB frame (1 ms) on its own clock, and QEMU
// keeps about 60 ms of them queued to serve the guest's transfers. The endpoint is asynchronous,
// so a packet may carry 47-49 samples; that absorbs the drift between the Mac's audio clock and
// the frame clock without gaps.
#import "microphone.h"
#import <AVFoundation/AVFoundation.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <fcntl.h>
#include <unistd.h>

// --- usb-redir protocol subset (spice/usbredir, usbredirproto.h) ---------------------------
enum { R_HELLO=0, R_DEVICE_CONNECT=1, R_RESET=3, R_INTERFACE_INFO=4, R_EP_INFO=5,
       R_SET_CONFIGURATION=6, R_GET_CONFIGURATION=7, R_CONFIGURATION_STATUS=8,
       R_SET_ALT_SETTING=9, R_GET_ALT_SETTING=10, R_ALT_SETTING_STATUS=11,
       R_START_ISO_STREAM=12, R_STOP_ISO_STREAM=13, R_ISO_STREAM_STATUS=14,
       R_CONTROL_PACKET=100, R_ISO_PACKET=102 };
enum { ST_SUCCESS=0, ST_INVAL=2, ST_STALL=4 };
enum { CAP_CONNECT_DEVICE_VERSION=1, CAP_EP_INFO_MAX_PACKET_SIZE=4, CAP_64BITS_IDS=5, CAP_32BITS_BULK_LENGTH=6 };
enum { TYPE_ISO=1 };
#pragma pack(push,1)
typedef struct { uint8_t endpoint, request, requesttype, status; uint16_t value, index, length; } CtrlHdr;
typedef struct { uint8_t endpoint, status; uint16_t length; } IsoHdr;
#pragma pack(pop)

// --- UAC1 device description ---------------------------------------------------------------
enum { kRate = 48000, kPerFrame = kRate / 1000, kMaxPacket = 100, kEpAudio = 0x81 };
// Samples queued between the Mac microphone and the packets: aim for 20 ms, never keep more than
// 120 ms (old sound is worse than a skip).
enum { kTargetFill = 960, kMaxFill = 5760 };
// USB vendor:product id (the Linux audio gadget's). GBOS_MIC_ID=vvvv:pppp overrides it.
static uint16_t gVendor = 0x1d6b, gProduct = 0x0101;
static void LoadIds(void) {
  const char *e = getenv("GBOS_MIC_ID"); unsigned v, p;
  if (e && sscanf(e, "%x:%x", &v, &p) == 2) { gVendor = v; gProduct = p; }
}

static void put8(NSMutableData *d, uint8_t v) { [d appendBytes:&v length:1]; }
static void put16(NSMutableData *d, uint16_t v) { put8(d, v & 0xff); put8(d, v >> 8); }

static NSData *DeviceDescriptor(void) {
  NSMutableData *d = [NSMutableData data];
  put8(d, 18); put8(d, 1); put16(d, 0x0200);
  put8(d, 0); put8(d, 0); put8(d, 0);                    // class is per interface
  put8(d, 64); put16(d, gVendor); put16(d, gProduct);
  put16(d, 0x0100); put8(d, 1); put8(d, 2); put8(d, 0); put8(d, 1);
  return d;
}

static NSData *ConfigDescriptor(void) {
  // Audio control: microphone input terminal (1) -> USB streaming output terminal (2).
  NSMutableData *ac = [NSMutableData data];
  put8(ac, 12); put8(ac, 0x24); put8(ac, 0x02); put8(ac, 1); put16(ac, 0x0201); put8(ac, 0);
  put8(ac, 1); put16(ac, 0); put8(ac, 0); put8(ac, 0);
  put8(ac, 9); put8(ac, 0x24); put8(ac, 0x03); put8(ac, 2); put16(ac, 0x0101); put8(ac, 0); put8(ac, 1); put8(ac, 0);
  NSMutableData *body = [NSMutableData data];
  put8(body, 9); put8(body, 4); put8(body, 0); put8(body, 0); put8(body, 0); put8(body, 1); put8(body, 1); put8(body, 0); put8(body, 0);
  put8(body, 9); put8(body, 0x24); put8(body, 0x01); put16(body, 0x0100); put16(body, 9 + ac.length); put8(body, 1); put8(body, 1);
  [body appendData:ac];
  // Audio streaming: alt 0 has no endpoint (no bandwidth reserved), alt 1 streams.
  put8(body, 9); put8(body, 4); put8(body, 1); put8(body, 0); put8(body, 0); put8(body, 1); put8(body, 2); put8(body, 0); put8(body, 0);
  put8(body, 9); put8(body, 4); put8(body, 1); put8(body, 1); put8(body, 1); put8(body, 1); put8(body, 2); put8(body, 0); put8(body, 0);
  put8(body, 7); put8(body, 0x24); put8(body, 0x01); put8(body, 2); put8(body, 1); put16(body, 0x0001);   // PCM, linked to terminal 2
  put8(body, 11); put8(body, 0x24); put8(body, 0x02); put8(body, 1); put8(body, 1); put8(body, 2); put8(body, 16); put8(body, 1);
  put8(body, kRate & 0xff); put8(body, (kRate >> 8) & 0xff); put8(body, kRate >> 16);                   // type I: mono, 16-bit, 48 kHz
  put8(body, 9); put8(body, 5); put8(body, kEpAudio); put8(body, 0x05); put16(body, kMaxPacket); put8(body, 1); put8(body, 0); put8(body, 0);
  put8(body, 7); put8(body, 0x25); put8(body, 0x01); put8(body, 0); put8(body, 0); put16(body, 0);         // no endpoint controls
  NSMutableData *cfg = [NSMutableData data];
  put8(cfg, 9); put8(cfg, 2); put16(cfg, 9 + body.length); put8(cfg, 2); put8(cfg, 1); put8(cfg, 0); put8(cfg, 0x80); put8(cfg, 50);
  [cfg appendData:body];
  return cfg;
}

static NSData *StringDescriptor(uint8_t index) {
  NSMutableData *d = [NSMutableData data];
  if (index == 0) { put8(d, 4); put8(d, 3); put16(d, 0x0409); return d; }
  NSString *s = index == 1 ? @"gbos-vm" : index == 2 ? @"Mac Microphone" : nil;
  if (!s) return nil;
  put8(d, 2 + 2 * s.length); put8(d, 3);
  for (NSUInteger i = 0; i < s.length; i++) put16(d, [s characterAtIndex:i]);
  return d;
}

static BOOL Debug(void) { static int on = -1; if (on < 0) on = getenv("GBOS_WEBCAM_DEBUG") != NULL; return on; }

// --- The device ----------------------------------------------------------------------------
@implementation GBMicrophone {
  NSString *_path;
  dispatch_queue_t _q;
  int _fd;
  dispatch_source_t _readSource, _writeSource, _packetTimer;
  BOOL _writeSuspended, _stopped;
  NSMutableData *_in, *_out;
  uint32_t _peerCaps;
  BOOL _ids64;
  uint8_t _configuration, _alt;
  // Streaming, all on _q.
  BOOL _streaming;
  uint64_t _streamStart, _packetsSent, _packetId;
  NSMutableData *_pcm;          // 16-bit mono samples from the Mac, oldest first
  // Capture. The engine is only touched on the main queue.
  AVAudioEngine *_engine;
  BOOL _capturing;              // _q only
}

- (instancetype)initWithSocketPath:(NSString *)path {
  if (!(self = [super init])) return nil;
  _path = [path copy]; _fd = -1; LoadIds();
  _q = dispatch_queue_create("gbos.microphone", DISPATCH_QUEUE_SERIAL);
  _pcm = [NSMutableData data];
  return self;
}

- (void)start { dispatch_async(_q, ^{ self->_stopped = NO; [self connect]; }); }

- (void)stop {
  dispatch_sync(_q, ^{ self->_stopped = YES; [self disconnect]; });
}

// --- Socket (same framing as host/webcam.m) -------------------------------------------------
- (void)connect {
  if (_stopped || _fd >= 0) return;
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  struct sockaddr_un a = {.sun_family = AF_UNIX};
  strlcpy(a.sun_path, _path.fileSystemRepresentation, sizeof a.sun_path);
  if (fd < 0 || connect(fd, (struct sockaddr *)&a, sizeof a) != 0) {
    if (fd >= 0) close(fd);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), _q, ^{ [self connect]; });
    return;
  }
  fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
  int one = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
  _fd = fd; _in = [NSMutableData data]; _out = [NSMutableData data]; _peerCaps = 0;
  _configuration = 0; _alt = 0; _ids64 = NO;
  _readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, _q);
  dispatch_source_set_event_handler(_readSource, ^{ [self readable]; });
  dispatch_resume(_readSource);
  _writeSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE, fd, 0, _q);
  dispatch_source_set_event_handler(_writeSource, ^{ [self flush]; });
  _writeSuspended = YES;
  uint8_t hello[68] = {0};
  strlcpy((char *)hello, "gbos-vm microphone 1", 64);
  uint32_t caps = (1u << CAP_CONNECT_DEVICE_VERSION) | (1u << CAP_EP_INFO_MAX_PACKET_SIZE) |
                  (1u << CAP_64BITS_IDS) | (1u << CAP_32BITS_BULK_LENGTH);
  OSWriteLittleInt32(hello, 64, caps);
  [self send:R_HELLO id:0 header:hello length:sizeof hello data:nil];
  NSLog(@"microphone: connected to %@", _path);
}

- (void)disconnect {
  [self stopStream];
  if (_readSource) { dispatch_source_cancel(_readSource); _readSource = nil; }
  if (_writeSource) { if (_writeSuspended) dispatch_resume(_writeSource); dispatch_source_cancel(_writeSource); _writeSource = nil; }
  if (_fd >= 0) { close(_fd); _fd = -1; }
}

- (void)readable {
  uint8_t buf[16384];
  for (;;) {
    ssize_t n = read(_fd, buf, sizeof buf);
    if (n > 0) { [_in appendBytes:buf length:n]; continue; }
    if (n < 0 && errno == EAGAIN) break;
    NSLog(@"microphone: QEMU closed the link");
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
- (void)packet:(uint32_t)type id:(uint64_t)pid body:(const uint8_t *)b length:(uint32_t)len {
  if (Debug() && type != R_CONTROL_PACKET) NSLog(@"microphone: packet type=%u id=%llu len=%u", type, pid, len);
  switch (type) {
    case R_HELLO:
      if (len >= 68) _peerCaps = OSReadLittleInt32(b, 64);
      _ids64 = (_peerCaps >> CAP_64BITS_IDS) & 1;
      [self plugIn];
      break;
    case R_SET_CONFIGURATION: {
      uint8_t cfg = len ? b[0] : 0, ok = cfg <= 1;
      if (ok) { _configuration = cfg; _alt = 0; [self stopStream]; }
      uint8_t st[2] = {ok ? ST_SUCCESS : ST_STALL, _configuration};
      [self send:R_CONFIGURATION_STATUS id:pid header:st length:2 data:nil];
      break; }
    case R_GET_CONFIGURATION: {
      uint8_t st[2] = {ST_SUCCESS, _configuration};
      [self send:R_CONFIGURATION_STATUS id:pid header:st length:2 data:nil];
      break; }
    case R_SET_ALT_SETTING: {
      uint8_t iface = len > 0 ? b[0] : 0, alt = len > 1 ? b[1] : 0;
      BOOL ok = (iface == 0 && alt == 0) || (iface == 1 && alt <= 1);
      if (ok && iface == 1) { _alt = alt; if (!alt) [self stopStream]; }
      uint8_t st[3] = {ok ? ST_SUCCESS : ST_INVAL, iface, iface == 1 ? _alt : 0};
      [self send:R_ALT_SETTING_STATUS id:pid header:st length:3 data:nil];
      break; }
    case R_GET_ALT_SETTING: {
      uint8_t iface = len ? b[0] : 0;
      uint8_t st[3] = {ST_SUCCESS, iface, iface == 1 ? _alt : 0};
      [self send:R_ALT_SETTING_STATUS id:pid header:st length:3 data:nil];
      break; }
    case R_START_ISO_STREAM: {
      uint8_t ep = len ? b[0] : 0, ok = ep == kEpAudio;
      uint8_t st[2] = {ok ? ST_SUCCESS : ST_STALL, ep};
      [self send:R_ISO_STREAM_STATUS id:pid header:st length:2 data:nil];
      if (ok) [self startStream];
      break; }
    case R_STOP_ISO_STREAM: {
      uint8_t st[2] = {ST_SUCCESS, len ? b[0] : 0};
      [self stopStream];
      [self send:R_ISO_STREAM_STATUS id:pid header:st length:2 data:nil];
      break; }
    case R_RESET:
      _configuration = 0; _alt = 0; [self stopStream];
      break;
    case R_CONTROL_PACKET:
      if (len >= sizeof(CtrlHdr)) { CtrlHdr h; memcpy(&h, b, sizeof h); [self control:pid header:h]; }
      break;
    default:
      break;   // no bulk or interrupt endpoints
  }
}

- (void)plugIn {
  BOOL mps = (_peerCaps >> CAP_EP_INFO_MAX_PACKET_SIZE) & 1, ver = (_peerCaps >> CAP_CONNECT_DEVICE_VERSION) & 1;
  // ep_info: index = ((address & 0x80) >> 3) | (address & 0x0f); then type, interval, interface,
  // and (with the capability) max packet size, 32 of each.
  uint8_t ep[96 + 64] = {0};
  memset(ep, 255, 32);
  ep[0] = 0; ep[16] = 0;                                   // control endpoint 0, both directions
  ep[17] = TYPE_ISO; ep[32 + 17] = 1; ep[64 + 17] = 1;     // 0x81 iso IN, every frame, interface 1
  OSWriteLittleInt16(ep, 96 + 0 * 2, 64); OSWriteLittleInt16(ep, 96 + 16 * 2, 64); OSWriteLittleInt16(ep, 96 + 17 * 2, kMaxPacket);
  [self send:R_EP_INFO id:0 header:ep length:mps ? sizeof ep : 96 data:nil];
  uint8_t ii[4 + 128] = {0};
  OSWriteLittleInt32(ii, 0, 2);
  ii[4] = 0; ii[5] = 1; ii[36] = 1; ii[37] = 1; ii[68] = 1; ii[69] = 2;   // audio control, audio streaming
  [self send:R_INTERFACE_INFO id:0 header:ii length:sizeof ii data:nil];
  uint8_t dc[10] = {1 /* full speed */, 0, 0, 0};
  OSWriteLittleInt16(dc, 4, gVendor); OSWriteLittleInt16(dc, 6, gProduct); OSWriteLittleInt16(dc, 8, 0x0100);
  [self send:R_DEVICE_CONNECT id:0 header:dc length:ver ? 10 : 8 data:nil];
  NSLog(@"microphone: plugged in");
}

- (void)reply:(uint64_t)pid header:(CtrlHdr)h status:(uint8_t)status data:(NSData *)data {
  if (data.length > h.length) data = [data subdataWithRange:NSMakeRange(0, h.length)];
  if (Debug()) NSLog(@"microphone: ctrl rt=%02x req=%02x val=%04x idx=%04x -> status=%u bytes=%lu",
                     h.requesttype, h.request, h.value, h.index, status, (unsigned long)data.length);
  h.status = status;
  if (h.endpoint & 0x80) h.length = status == ST_SUCCESS ? data.length : 0;
  [self send:R_CONTROL_PACKET id:pid header:&h length:sizeof h data:(h.endpoint & 0x80) ? data : nil];
}

- (void)control:(uint64_t)pid header:(CtrlHdr)h {
  uint8_t type = h.value >> 8, idx = h.value & 0xff;
  if (h.requesttype == 0x80 && h.request == 6) {            // GET_DESCRIPTOR
    NSData *d = type == 1 ? DeviceDescriptor() : type == 2 ? ConfigDescriptor() : type == 3 ? StringDescriptor(idx) : nil;
    [self reply:pid header:h status:d ? ST_SUCCESS : ST_STALL data:d];
  } else if ((h.requesttype & 0xfc) == 0x80 && h.request == 0) {   // GET_STATUS
    [self reply:pid header:h status:ST_SUCCESS data:[NSData dataWithBytes:"\0\0" length:2]];
  } else if ((h.requesttype & 0xfc) == 0x00 && (h.request == 1 || h.request == 3)) {   // CLEAR/SET_FEATURE
    [self reply:pid header:h status:ST_SUCCESS data:nil];
  } else {
    [self reply:pid header:h status:ST_STALL data:nil];    // no audio class controls
  }
}

// --- Isochronous stream ---------------------------------------------------------------------
- (void)startStream {
  if (_streaming) return;
  _streaming = YES; _packetsSent = 0; _streamStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
  [_pcm setLength:0];
  [self startCapture];
  _packetTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _q);
  dispatch_source_set_timer(_packetTimer, DISPATCH_TIME_NOW, 4 * NSEC_PER_MSEC, NSEC_PER_MSEC);
  dispatch_source_set_event_handler(_packetTimer, ^{ [self pump]; });
  dispatch_resume(_packetTimer);
  NSLog(@"microphone: guest started recording");
}

- (void)stopStream {
  if (!_streaming) return;
  _streaming = NO;
  if (_packetTimer) { dispatch_source_cancel(_packetTimer); _packetTimer = nil; }
  [self stopCapture];
  NSLog(@"microphone: guest stopped recording after %llu ms", _packetsSent);
}

// Send every packet due since the stream started: one per 1 ms USB frame.
- (void)pump {
  uint64_t due = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - _streamStart) / NSEC_PER_MSEC + 1;
  if (due > _packetsSent + 200) _packetsSent = due - 60;   // we were held up; don't flood QEMU
  while (_packetsSent < due && _fd >= 0) {
    NSUInteger have = _pcm.length / 2;
    // Steer the queue towards kTargetFill by sending a sample more or less.
    NSUInteger n = have > kTargetFill * 3 / 2 ? kPerFrame + 1 : have < kTargetFill / 2 ? kPerFrame - 1 : kPerFrame;
    NSMutableData *samples = [NSMutableData dataWithLength:n * 2];   // silence where the Mac fell short
    NSUInteger take = MIN(n, have);
    if (take) {
      memcpy(samples.mutableBytes, _pcm.bytes, take * 2);
      [_pcm replaceBytesInRange:NSMakeRange(0, take * 2) withBytes:NULL length:0];
    }
    IsoHdr h = {kEpAudio, ST_SUCCESS, (uint16_t)(n * 2)};
    [self send:R_ISO_PACKET id:_packetId++ header:&h length:sizeof h data:samples];
    _packetsSent++;
  }
}

- (void)addSamples:(NSData *)pcm {
  if (!_streaming) return;
  [_pcm appendData:pcm];
  NSUInteger have = _pcm.length / 2;
  if (have > kMaxFill) [_pcm replaceBytesInRange:NSMakeRange(0, (have - kTargetFill) * 2) withBytes:NULL length:0];
}

// --- Mac microphone -------------------------------------------------------------------------
- (void)startCapture {
  if (_capturing) return;
  _capturing = YES;
  dispatch_queue_t q = _q;
  void (^begin)(void) = ^{
    dispatch_async(dispatch_get_main_queue(), ^{
      __block BOOL wanted = NO;
      dispatch_sync(q, ^{ wanted = self->_capturing; });
      if (!wanted || self->_engine) return;
      AVAudioEngine *engine = [AVAudioEngine new];
      AVAudioInputNode *input = engine.inputNode;
      AVAudioFormat *inFormat = [input outputFormatForBus:0];
      if (inFormat.sampleRate <= 0 || inFormat.channelCount == 0) { NSLog(@"microphone: no Mac microphone available"); return; }
      AVAudioFormat *outFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16 sampleRate:kRate channels:1 interleaved:YES];
      AVAudioConverter *convert = [[AVAudioConverter alloc] initFromFormat:inFormat toFormat:outFormat];
      if (!convert) { NSLog(@"microphone: can't convert from %@", inFormat); return; }
      __weak GBMicrophone *weakSelf = self;
      [input installTapOnBus:0 bufferSize:1024 format:inFormat block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        AVAudioFrameCount room = (AVAudioFrameCount)ceil(buffer.frameLength * kRate / inFormat.sampleRate) + 32;
        AVAudioPCMBuffer *out = [[AVAudioPCMBuffer alloc] initWithPCMFormat:outFormat frameCapacity:room];
        __block BOOL fed = NO;
        [convert convertToBuffer:out error:nil withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount count, AVAudioConverterInputStatus *status) {
          if (fed) { *status = AVAudioConverterInputStatus_NoDataNow; return nil; }
          fed = YES; *status = AVAudioConverterInputStatus_HaveData; return buffer;
        }];
        if (!out.frameLength) return;
        NSData *pcm = [NSData dataWithBytes:out.int16ChannelData[0] length:out.frameLength * 2];
        dispatch_async(q, ^{ [weakSelf addSamples:pcm]; });
      }];
      NSError *err = nil;
      if (![engine startAndReturnError:&err]) {
        NSLog(@"microphone: can't start the Mac microphone: %@", err);
        [input removeTapOnBus:0];
        return;
      }
      self->_engine = engine;
      NSLog(@"microphone: Mac microphone on (%.0f Hz, %u channels)", inFormat.sampleRate, inFormat.channelCount);
    });
  };
  AVAuthorizationStatus access = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
  if (access == AVAuthorizationStatusAuthorized) begin();
  else if (access == AVAuthorizationStatusNotDetermined)
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) { if (granted) begin(); }];
  else NSLog(@"microphone: access denied (System Settings > Privacy & Security > Microphone)");
}

- (void)stopCapture {
  if (!_capturing) return;
  _capturing = NO;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!self->_engine) return;
    [self->_engine.inputNode removeTapOnBus:0];
    [self->_engine stop];
    self->_engine = nil;
    NSLog(@"microphone: Mac microphone off");
  });
}
@end
