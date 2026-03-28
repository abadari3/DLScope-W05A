#import "DLSMicroscope.h"
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <SystemConfiguration/CaptiveNetwork.h>

#define MICROSCOPE_IP   "192.168.1.1"
#define CMD_PORT        10005
#define STREAM_REG_PORT 10006
#define HB_PORT         10007
#define STREAM_RX_PORT  10900

static const uint8_t kMagic[4] = {0xEE, 0xFF, 0xEE, 0xFF};

#pragma mark - Command building

static NSData *makeCmd(uint16_t seq, uint16_t cmd, uint32_t param) {
    uint8_t buf[12];
    memcpy(buf, kMagic, 4);
    buf[4] = seq & 0xFF;
    buf[5] = (seq >> 8) & 0xFF;
    buf[6] = cmd & 0xFF;
    buf[7] = (cmd >> 8) & 0xFF;
    buf[8] = param & 0xFF;
    buf[9] = (param >> 8) & 0xFF;
    buf[10] = (param >> 16) & 0xFF;
    buf[11] = (param >> 24) & 0xFF;
    return [NSData dataWithBytes:buf length:12];
}

static NSData *makeStreamRegCmd(void) {
    // pack("<4sHHHHI", MAGIC, 2, 4, 1, 2, 10900)
    uint8_t buf[16];
    memcpy(buf, kMagic, 4);
    buf[4] = 2; buf[5] = 0;   // seq = 2
    buf[6] = 4; buf[7] = 0;   // cmd = 4
    buf[8] = 1; buf[9] = 0;   // param1 = 1
    buf[10] = 2; buf[11] = 0; // param2 = 2
    uint32_t port = STREAM_RX_PORT;
    memcpy(buf + 12, &port, 4);
    return [NSData dataWithBytes:buf length:16];
}

#pragma mark - Socket helpers

static int createUDPSocket(uint16_t bindPort) {
    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) return -1;

    int rcvbuf = 2 * 1024 * 1024;
    setsockopt(sock, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));

    if (bindPort > 0) {
        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_port = htons(bindPort);
        addr.sin_addr.s_addr = INADDR_ANY;
        if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
            close(sock);
            return -1;
        }
    }
    return sock;
}

static void sendToMicroscope(int sock, NSData *data, uint16_t port) {
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    inet_aton(MICROSCOPE_IP, &addr.sin_addr);
    sendto(sock, [data bytes], [data length], 0,
           (struct sockaddr *)&addr, sizeof(addr));
}

static void sendEmptyToMicroscope(int sock, uint16_t port) {
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    inet_aton(MICROSCOPE_IP, &addr.sin_addr);
    sendto(sock, NULL, 0, 0, (struct sockaddr *)&addr, sizeof(addr));
}

#pragma mark - WiFi check

static BOOL isOnMicroscopeWiFi(void) {
    CFArrayRef interfaces = CNCopySupportedInterfaces();
    if (!interfaces) return NO;
    BOOL found = NO;
    CFIndex count = CFArrayGetCount(interfaces);
    for (CFIndex i = 0; i < count; i++) {
        CFStringRef iface = CFArrayGetValueAtIndex(interfaces, i);
        CFDictionaryRef info = CNCopyCurrentNetworkInfo(iface);
        if (info) {
            CFStringRef ssid = CFDictionaryGetValue(info, kCNNetworkInfoKeySSID);
            if (ssid && CFStringHasPrefix(ssid, CFSTR("MKL_WIFI_"))) {
                found = YES;
            }
            CFRelease(info);
        }
        if (found) break;
    }
    CFRelease(interfaces);
    return found;
}

#pragma mark - JPEG decoding (reusable context)

// Persistent decode context — allocated once, reused every frame.
// All frames are 640x480 so the backing buffer never needs to change.
static CGColorSpaceRef sColorSpace = NULL;
static CGContextRef sDecodeCtx = NULL;
static size_t sDecodeW = 0;
static size_t sDecodeH = 0;

static void ensureDecodeContext(size_t w, size_t h) {
    if (sDecodeCtx && sDecodeW == w && sDecodeH == h) return;
    if (sDecodeCtx) CGContextRelease(sDecodeCtx);
    if (!sColorSpace) sColorSpace = CGColorSpaceCreateDeviceRGB();
    sDecodeCtx = CGBitmapContextCreate(NULL, w, h, 8, w * 4, sColorSpace,
                                        kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Host);
    sDecodeW = w;
    sDecodeH = h;
}

static UIImage *decodeJPEG(const uint8_t *bytes, size_t length) {
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, bytes, length, NULL);
    if (!provider) return nil;

    CGImageRef cgImage = CGImageCreateWithJPEGDataProvider(provider, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    if (!cgImage) return nil;

    size_t w = CGImageGetWidth(cgImage);
    size_t h = CGImageGetHeight(cgImage);
    ensureDecodeContext(w, h);
    if (!sDecodeCtx) {
        CGImageRelease(cgImage);
        return nil;
    }

    // Force JPEG decompression now (on background thread)
    CGContextDrawImage(sDecodeCtx, CGRectMake(0, 0, w, h), cgImage);
    CGImageRelease(cgImage);

    CGImageRef decoded = CGBitmapContextCreateImage(sDecodeCtx);
    if (!decoded) return nil;

    // UIImageOrientationRight = display rotated 90° CW (landscape→portrait)
    UIImage *image = [UIImage imageWithCGImage:decoded scale:1.0 orientation:UIImageOrientationRight];
    CGImageRelease(decoded);
    return image;
}

#pragma mark - DLSMicroscope

@implementation DLSMicroscope {
    int _cmdSock;
    int _streamSock;
    int _hbSock;
    BOOL _running;
    NSThread *_streamThread;
    NSThread *_hbThread;
    uint8_t _lastSnapBtn;
    UIImage *_pendingFrame;
    BOOL _frameDispatched;
}

- (void)dealloc {
    [self stop];
}

- (void)start {
    _running = YES;

    if (!isOnMicroscopeWiFi()) {
        [self notifyStatus:@"Connect to MKL_WIFI network"];
    }

    _cmdSock = createUDPSocket(0);
    _streamSock = createUDPSocket(STREAM_RX_PORT);
    _hbSock = createUDPSocket(HB_PORT);

    if (_cmdSock < 0 || _streamSock < 0 || _hbSock < 0) {
        [self notifyStatus:@"Failed to create sockets"];
        return;
    }

    // Send registration commands
    sendToMicroscope(_cmdSock, makeCmd(0, 1, 1), CMD_PORT);
    sendToMicroscope(_cmdSock, makeCmd(1, 2, 1), CMD_PORT);
    sendToMicroscope(_cmdSock, makeStreamRegCmd(), STREAM_REG_PORT);

    // Start heartbeat thread
    _hbThread = [[NSThread alloc] initWithTarget:self selector:@selector(heartbeatLoop) object:nil];
    _hbThread.name = @"DLScope-Heartbeat";
    [_hbThread start];

    // Start stream receiver thread
    _streamThread = [[NSThread alloc] initWithTarget:self selector:@selector(streamLoop) object:nil];
    _streamThread.name = @"DLScope-Stream";
    [_streamThread start];
}

- (void)stop {
    _running = NO;
    if (_cmdSock >= 0) { close(_cmdSock); _cmdSock = -1; }
    if (_streamSock >= 0) { close(_streamSock); _streamSock = -1; }
    if (_hbSock >= 0) { close(_hbSock); _hbSock = -1; }
}

- (void)notifyStatus:(NSString *)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate microscopeDidUpdateStatus:status];
    });
}

- (void)notifyFrame:(UIImage *)image {
    // Pending frame slot: always keep only the latest frame.
    // If main thread hasn't consumed the previous one, it gets replaced.
    _pendingFrame = image;

    if (!_frameDispatched) {
        _frameDispatched = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            UIImage *latest = _pendingFrame;
            _frameDispatched = NO;
            [self.delegate microscopeDidReceiveFrame:latest];
        });
    }
}

#pragma mark - Heartbeat

- (void)heartbeatLoop {
    @autoreleasepool {
        uint8_t buf[256];
        struct timeval tv;
        tv.tv_sec = 1;
        tv.tv_usec = 0;
        setsockopt(_hbSock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

        while (_running) {
            ssize_t n = recvfrom(_hbSock, buf, sizeof(buf), 0, NULL, NULL);
            if (n >= 4 && memcmp(buf, kMagic, 4) == 0) {
                sendEmptyToMicroscope(_hbSock, HB_PORT);
                // Hardware snap button: byte 8 transitions from 0 to 1
                if (n > 8) {
                    uint8_t btn = buf[8];
                    if (btn == 1 && _lastSnapBtn == 0) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if ([self.delegate respondsToSelector:@selector(microscopeDidPressSnapButton)]) {
                                [self.delegate microscopeDidPressSnapButton];
                            }
                        });
                    }
                    _lastSnapBtn = btn;
                }
            }
        }
    }
}

#pragma mark - Stream

- (void)streamLoop {
    @autoreleasepool {
        // Pre-allocated C buffers — no NSMutableData overhead or reallocation
        uint8_t pktBuf[65536];
        static const size_t kFrameBufCap = 120 * 1024;
        uint8_t *frameBuf = (uint8_t *)malloc(kFrameBufCap);
        size_t frameLen = 0;

        uint8_t lastFrameNum = 0;
        BOOL haveFrame = NO;
        uint16_t expectIdx = 1;
        BOOL frameDirty = NO;
        struct timeval tv;
        tv.tv_sec = 5;
        tv.tv_usec = 0;
        setsockopt(_streamSock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

        while (_running) {
            ssize_t n = recvfrom(_streamSock, pktBuf, sizeof(pktBuf), 0, NULL, NULL);

            if (n < 0) {
                // Timeout — check WiFi and re-register
                if (!isOnMicroscopeWiFi()) {
                    [self notifyStatus:@"Connect to MKL_WIFI network"];
                } else {
                    [self notifyStatus:@"Timeout - reconnecting..."];
                }
                sendToMicroscope(_cmdSock, makeCmd(0, 1, 1), CMD_PORT);
                sendToMicroscope(_cmdSock, makeCmd(1, 2, 1), CMD_PORT);
                sendToMicroscope(_cmdSock, makeStreamRegCmd(), STREAM_REG_PORT);
                continue;
            }

            // Skip command responses
            if (n >= 4 && memcmp(pktBuf, kMagic, 4) == 0) {
                continue;
            }

            if (n <= 16) continue;

            uint8_t frameNum = pktBuf[2];
            uint8_t lastFlag = pktBuf[3];
            uint16_t pktIdx = pktBuf[4] | (pktBuf[5] << 8);

            // New frame started before previous finished
            if (haveFrame && frameNum != lastFrameNum) {
                frameLen = 0;
                expectIdx = 1;
                frameDirty = NO;
            }
            lastFrameNum = frameNum;
            haveFrame = YES;

            // Detect gaps — mark frame dirty
            if (pktIdx != expectIdx) {
                frameDirty = YES;
            }
            expectIdx = pktIdx + 1;

            size_t payloadLen = n - 16;
            if (frameLen + payloadLen <= kFrameBufCap) {
                memcpy(frameBuf + frameLen, pktBuf + 16, payloadLen);
                frameLen += payloadLen;
            } else {
                frameDirty = YES;
            }

            if (lastFlag != 1) continue;

            // Frame complete
            expectIdx = 1;

            // Skip dirty frames (missing packets = glitchy JPEG)
            if (frameDirty) {
                frameLen = 0;
                frameDirty = NO;
                continue;
            }
            frameDirty = NO;

            if (frameLen < 2 || frameBuf[0] != 0xFF || frameBuf[1] != 0xD8) {
                frameLen = 0;
                continue;
            }

            // Skip decode if main thread hasn't consumed the previous frame yet
            if (_frameDispatched) {
                frameLen = 0;
                continue;
            }

            UIImage *image = decodeJPEG(frameBuf, frameLen);
            frameLen = 0;

            if (!image) continue;

            [self notifyFrame:image];
        }

        free(frameBuf);
        if (sDecodeCtx) { CGContextRelease(sDecodeCtx); sDecodeCtx = NULL; }
        if (sColorSpace) { CGColorSpaceRelease(sColorSpace); sColorSpace = NULL; }
        sDecodeW = sDecodeH = 0;
    }
}

@end
