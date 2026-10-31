//
//  BXCaptureBridge.m
//

#import "BXCaptureBridge.h"
#import "BXVideoSource.h"
#import "BXStreamVideoSource.h"
#import "BXFFmpegRTSP.h"
#import "BXSwizzle.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreImage/CoreImage.h>   // CIContext / CIImage（像素格式转换要用）

static const void *kBXOrigDelegateKey = &kBXOrigDelegateKey;
static const void *kBXOrigQueueKey    = &kBXOrigQueueKey;

// 前置声明（install 里先用到）
static void BXSetSampleBufferDelegate(id self, SEL _cmd, id delegate, dispatch_queue_t queue);
static id   BXGetSampleBufferDelegate(id self, SEL _cmd);


// ─────────────────────────────────────────────────────────────
//  把 BGRA 帧转成摄像头使用的像素格式。
//  抖音的采集管线是按摄像头的 420f(全范围)/420v(视频范围) 建的，
//  直接塞 BGRA 即使格式描述写对了，后面处理链也可能不认。
// ─────────────────────────────────────────────────────────────
static CVPixelBufferRef BXConvertPixelBuffer(CVPixelBufferRef src, OSType dstFmt) CF_RETURNS_RETAINED {
    if (!src) return NULL;
    OSType srcFmt = CVPixelBufferGetPixelFormatType(src);
    if (srcFmt == dstFmt) return (CVPixelBufferRef)CFRetain(src);

    size_t w = CVPixelBufferGetWidth(src);
    size_t h = CVPixelBufferGetHeight(src);
    if (w == 0 || h == 0) return NULL;

    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(dstFmt),
        (id)kCVPixelBufferWidthKey: @(w),
        (id)kCVPixelBufferHeightKey: @(h),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVPixelBufferRef dst = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, dstFmt,
                            (__bridge CFDictionaryRef)attrs, &dst) != kCVReturnSuccess || !dst) {
        return NULL;
    }

    static CIContext *ctx = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ctx = [CIContext contextWithOptions:nil]; });

    CIImage *img = [CIImage imageWithCVPixelBuffer:src];
    [ctx render:img toCVPixelBuffer:dst
           bounds:CGRectMake(0, 0, w, h)
       colorSpace:CGColorSpaceCreateDeviceRGB()];
    return dst;
}


// ─────────────────────────────────────────────────────────────
//  照着百相的做法：不造新的 CMSampleBuffer，
//  直接把我们的帧「写进摄像头那一帧的 CVPixelBuffer」。
//  好处：像素格式、attachments、时间戳、格式描述全部天然一致，
//        不会出现 InvalidMediaFormat(-12743)，也不会 CFRelease(NULL)。
//  前提：src 与 dst 的尺寸、像素格式一致（调用方负责转换）。
// ─────────────────────────────────────────────────────────────
static BOOL BXBlitInto(CVPixelBufferRef dst, CVPixelBufferRef src) {
    if (!dst || !src) return NO;

    size_t dw = CVPixelBufferGetWidth(dst), dh = CVPixelBufferGetHeight(dst);
    size_t sw = CVPixelBufferGetWidth(src), sh = CVPixelBufferGetHeight(src);
    if (dw != sw || dh != sh) return NO;
    if (CVPixelBufferGetPixelFormatType(dst) != CVPixelBufferGetPixelFormatType(src)) return NO;

    if (CVPixelBufferLockBaseAddress(dst, 0) != kCVReturnSuccess) return NO;
    if (CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(dst, 0);
        return NO;
    }

    BOOL ok = YES;
    size_t planes = CVPixelBufferIsPlanar(dst) ? CVPixelBufferGetPlaneCount(dst) : 1;

    for (size_t pl = 0; pl < planes; pl++) {
        uint8_t *db = CVPixelBufferIsPlanar(dst)
                    ? (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(dst, pl)
                    : (uint8_t *)CVPixelBufferGetBaseAddress(dst);
        uint8_t *sb = CVPixelBufferIsPlanar(src)
                    ? (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(src, pl)
                    : (uint8_t *)CVPixelBufferGetBaseAddress(src);
        if (!db || !sb) { ok = NO; break; }

        size_t dbpr = CVPixelBufferIsPlanar(dst)
                    ? CVPixelBufferGetBytesPerRowOfPlane(dst, pl)
                    : CVPixelBufferGetBytesPerRow(dst);
        size_t sbpr = CVPixelBufferIsPlanar(src)
                    ? CVPixelBufferGetBytesPerRowOfPlane(src, pl)
                    : CVPixelBufferGetBytesPerRow(src);

        size_t rows = dh;
        size_t rowBytes = MIN(dbpr, sbpr);
        if (CVPixelBufferIsPlanar(dst) && pl > 0) {
            // 色度平面：高度是亮度的一半
            rows = (dh + 1) / 2;
            rowBytes = MIN(dbpr, sbpr);
        }

        for (size_t y = 0; y < rows; y++) {
            memcpy(db + y * dbpr, sb + y * sbpr, rowBytes);
        }
    }

    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(dst, 0);
    return ok;
}

@interface BXCaptureBridge () <AVCaptureVideoDataOutputSampleBufferDelegate,
                              AVCaptureAudioDataOutputSampleBufferDelegate>
@property (nonatomic, strong) BXVideoSource *source;
@property (nonatomic, strong) BXStreamVideoSource *stream;
@property (nonatomic, strong) BXFFmpegRTSP *rtsp;
@property (atomic, assign) BOOL installed;
@property (atomic, assign) NSUInteger replacedFrames;
@property (atomic, assign) NSUInteger passthroughFrames;
@property (atomic, assign) NSUInteger capturedOutputs;
@property (nonatomic, assign) NSUInteger attemptFrames;
@property (nonatomic, copy) NSString *gateReason;
@property (nonatomic, copy) NSString *buildError;
@end

@implementation BXCaptureBridge

+ (instancetype)shared {
    static BXCaptureBridge *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [BXCaptureBridge new]; });
    return inst;
}

- (instancetype)init {
    if (self = [super init]) {
        _source = [BXVideoSource new];
        _stream = [BXStreamVideoSource new];
        _rtsp = [BXFFmpegRTSP new];
        _enabled = NO;
        _installed = NO;
    }
    return self;
}

#pragma mark - 视频源

- (NSString *)sourcePath { return self.source.path; }

- (BOOL)loop   { return self.source.loop; }
- (void)setLoop:(BOOL)v { self.source.loop = v; }
- (BOOL)mirror { return self.rtsp.isRunning ? self.rtsp.mirror : (self.stream.isRunning ? self.stream.mirror : self.source.mirror); }
- (void)setMirror:(BOOL)v { self.source.mirror = v; self.stream.mirror = v; self.rtsp.mirror = v; }
- (NSInteger)rotation { return self.rtsp.isRunning ? self.rtsp.rotation : (self.stream.isRunning ? self.stream.rotation : self.source.rotation); }
- (void)setRotation:(NSInteger)v { self.source.rotation = v; self.stream.rotation = v; self.rtsp.rotation = v; }

- (BOOL)useRTSPURLString:(NSString *)urlString error:(NSError **)error {
    if (!urlString.length) return NO;
    BOOL ok = [self.rtsp startWithURLString:urlString error:error];
    if (ok) NSLog(@"[BXFloat][vcam] RTSP 已连接 %@", urlString);
    return ok;
}

- (NSString *)rtspURL { return self.rtsp.urlString; }

- (NSUInteger)decodedFrames { return self.rtsp.decodedFrames; }
- (NSString *)streamFrameReason { return self.rtsp.lastReason ?: @"-"; }

- (CVPixelBufferRef)copyLatestStreamFrame CF_RETURNS_RETAINED {
    if (self.rtsp.isRunning) return [self.rtsp copyNextFrameScaledTo:CGSizeZero];
    if (self.stream.isRunning) return [self.stream copyNextFrameScaledTo:CGSizeZero];
    return NULL;
}

- (void)stopNetworkSources {
    [self.rtsp stop];
    [self.stream stop];
    NSLog(@"[BXFloat][vcam] 网络源已停止");
}

- (BOOL)useStreamURLString:(NSString *)urlString error:(NSError **)error {
    if (!urlString.length) return NO;
    BOOL ok = [self.stream startWithURLString:urlString error:error];
    if (ok) NSLog(@"[BXFloat][vcam] 流媒体源已启动 %@", urlString);
    return ok;
}

- (NSString *)streamURL { return self.stream.urlString; }

- (BOOL)useVideoAtPath:(NSString *)path error:(NSError **)error {
    if (!path.length) return NO;
    return [self.source loadURL:[NSURL fileURLWithPath:path] error:error];
}

#pragma mark - 安装 hook

// Method 指针 -> 原始 IMP（按 Method 区分，避免父子类重复 patch 时串味）
static NSMutableDictionary *gSetOrig = nil;
static NSMutableDictionary *gGetOrig = nil;

static IMP BXOrigForMethod(NSMutableDictionary *map, Method m) {
    if (!map || !m) return NULL;
    NSValue *v = map[[NSValue valueWithPointer:m]];
    return v ? (IMP)v.pointerValue : NULL;
}

- (void)install {
    if (self.installed) return;

    SEL setSel = @selector(setSampleBufferDelegate:queue:);
    SEL getSel = @selector(sampleBufferDelegate);

    Class videoOut = NSClassFromString(@"AVCaptureVideoDataOutput");
    Class audioOut = NSClassFromString(@"AVCaptureAudioDataOutput");
    Class baseOut  = NSClassFromString(@"AVCaptureOutput");

    if (!gSetOrig) gSetOrig = [NSMutableDictionary dictionary];
    if (!gGetOrig) gGetOrig = [NSMutableDictionary dictionary];

    // setSampleBufferDelegate:queue: 可能定义在父类 AVCaptureOutput 上。
    // 若对 video 和 audio 各 patch 一次，会改到同一个 Method 造成 IMP 链错乱，
    // 所以先按 Method 指针去重。
    NSMutableArray *setMethods = [NSMutableArray array];
    NSMutableArray *getMethods = [NSMutableArray array];

    void (^collect)(Class, SEL, NSMutableArray *) = ^(Class cls, SEL sel, NSMutableArray *out) {
        if (!cls) return;
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) return;
        NSValue *v = [NSValue valueWithPointer:m];
        if (![out containsObject:v]) [out addObject:v];
    };

    collect(videoOut, setSel, setMethods);
    collect(audioOut, setSel, setMethods);
    collect(baseOut,  setSel, setMethods);
    collect(videoOut, getSel, getMethods);
    collect(audioOut, getSel, getMethods);
    collect(baseOut,  getSel, getMethods);

    for (NSValue *v in setMethods) {
        Method m = (Method)v.pointerValue;
        IMP orig = method_setImplementation(m, (IMP)BXSetSampleBufferDelegate);
        gSetOrig[v] = [NSValue valueWithPointer:orig];
        NSLog(@"[BXFloat][vcam] setSampleBufferDelegate hooked method=%p orig=%p",
              (void *)m, (void *)orig);
    }
    for (NSValue *v in getMethods) {
        Method m = (Method)v.pointerValue;
        IMP orig = method_setImplementation(m, (IMP)BXGetSampleBufferDelegate);
        gGetOrig[v] = [NSValue valueWithPointer:orig];
        NSLog(@"[BXFloat][vcam] sampleBufferDelegate getter hooked method=%p", (void *)m);
    }

    self.installed = (setMethods.count > 0);
    NSLog(@"[BXFloat][vcam] bridge installed, %lu setter(s) / %lu getter(s)",
          (unsigned long)setMethods.count, (unsigned long)getMethods.count);
}

#pragma mark - swizzle 实现

static void BXSetSampleBufferDelegate(id self, SEL _cmd, id delegate, dispatch_queue_t queue) {
    // 记住 App 原本的 delegate / queue
    // 必须 RETAIN：AVCaptureVideoDataOutput 对 delegate 是弱引用，
    // 用 ASSIGN 存的话原 delegate 一释放，回调里转发就是野指针 → 进拍摄页必崩。
    objc_setAssociatedObject(self, kBXOrigDelegateKey, delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kBXOrigQueueKey, queue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSLog(@"[BXFloat][vcam] capture delegate bridge installed class=%@ original=%p",
          NSStringFromClass([self class]), (__bridge void *)delegate);

    BOOL isVideoOut = [self isKindOfClass:NSClassFromString(@"AVCaptureVideoDataOutput")];
    if (isVideoOut) {
        [BXCaptureBridge shared].capturedOutputs += 1;
    }

    if (!queue) queue = dispatch_get_main_queue();

    Method m = class_getInstanceMethod(object_getClass(self), _cmd);
    IMP orig = m ? BXOrigForMethod(gSetOrig, m) : NULL;
    if (!orig) {
        // 兜底：这个类可能不是我们直接 swizzle 的那个子类，往上找父类实现
        Class sup = class_getSuperclass(object_getClass(self));
        if (sup) {
            Method sm = class_getInstanceMethod(sup, _cmd);
            if (sm) orig = method_getImplementation(sm);
        }
    }
    if (orig) {
        ((void (*)(id, SEL, id, dispatch_queue_t))orig)(self, _cmd, [BXCaptureBridge shared], queue);
    } else {
        NSLog(@"[BXFloat][vcam] 拿不到原始 setSampleBufferDelegate 实现，本轮不接管 %@",
              NSStringFromClass([self class]));
    }
}

static id BXGetSampleBufferDelegate(id self, SEL _cmd) {
    id d = objc_getAssociatedObject(self, kBXOrigDelegateKey);
    if (d) return d;
    Method m = class_getInstanceMethod(object_getClass(self), _cmd);
    IMP orig = BXOrigForMethod(gGetOrig, m);
    if (orig) return ((id (*)(id, SEL))orig)(self, _cmd);
    return nil;
}

#pragma mark - 视频回调

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {

    BOOL isVideo = [output isKindOfClass:NSClassFromString(@"AVCaptureVideoDataOutput")];
    BOOL hasAnySource = self.rtsp.isRunning || self.stream.isRunning || self.source.loaded;

    if (isVideo) {
        if (!self.enabled)       self.gateReason = @"enabled = NO";
        else if (!hasAnySource)  self.gateReason = @"没有任何可用来源";
        else                     self.gateReason = @"ok";
    }

    if (isVideo && self.enabled && hasAnySource) {
        self.attemptFrames += 1;

        // 百相的做法：不造新 sample buffer，直接把像素写进摄像头这一帧。
        // 这样格式/attachments/时间戳天生一致，交给 App 的仍是它自己的 buffer。
        @try {
            CVImageBufferRef camPx = CMSampleBufferGetImageBuffer(sampleBuffer);
            if (camPx) {
                CGSize target = CGSizeMake(CVPixelBufferGetWidth(camPx),
                                           CVPixelBufferGetHeight(camPx));
                OSType camFmt = CVPixelBufferGetPixelFormatType(camPx);

                CVPixelBufferRef mine = NULL;
                if (self.rtsp.isRunning)        mine = [self.rtsp copyNextFrameScaledTo:target];
                else if (self.stream.isRunning) mine = [self.stream copyNextFrameScaledTo:target];
                else                            mine = [self.source copyNextFrameScaledTo:target];

                if (mine) {
                    // 把我们的帧转成摄像头同格式（尺寸已经按 target 缩放过）
                    CVPixelBufferRef conv = BXConvertPixelBuffer(mine, camFmt);
                    CVPixelBufferRef use = conv ? conv : mine;

                    if (BXBlitInto(camPx, use)) {
                        self.replacedFrames += 1;
                        self.buildError = @"已写入摄像头帧";
                        if (self.replacedFrames == 1 || self.replacedFrames % 120 == 0) {
                            NSLog(@"[BXFloat][vcam] 已写入 %lu 帧（直通 %lu）",
                                  (unsigned long)self.replacedFrames,
                                  (unsigned long)self.passthroughFrames);
                        }
                    } else {
                        self.buildError = [NSString stringWithFormat:@"写入失败 %zux%zu fmt=%08x",
                                           CVPixelBufferGetWidth(camPx),
                                           CVPixelBufferGetHeight(camPx),
                                           (unsigned)camFmt];
                        self.passthroughFrames += 1;
                    }

                    if (conv) CVPixelBufferRelease(conv);
                    CVPixelBufferRelease(mine);
                } else {
                    self.buildError = @"取帧为空";
                    self.passthroughFrames += 1;
                }
            }
        } @catch (NSException *e) {
            NSLog(@"[BXFloat][vcam] 写入异常 %@", e);
            self.buildError = @"写入异常";
        }
    } else if (isVideo) {
        self.passthroughFrames += 1;
    }

    // 永远转发原始 sample buffer（我们已经改过它的像素内容）
    id orig = objc_getAssociatedObject(output, kBXOrigDelegateKey);
    if ([orig respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        ((void (*)(id, SEL, id, CMSampleBufferRef, id))objc_msgSend)(
            orig, @selector(captureOutput:didOutputSampleBuffer:fromConnection:),
            output, sampleBuffer, connection);
    }
}

- (void)captureOutput:(AVCaptureOutput *)output
  didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    id orig = objc_getAssociatedObject(output, kBXOrigDelegateKey);
    if ([orig respondsToSelector:@selector(captureOutput:didDropSampleBuffer:fromConnection:)]) {
        ((void (*)(id, SEL, id, CMSampleBufferRef, id))objc_msgSend)(
            orig, @selector(captureOutput:didDropSampleBuffer:fromConnection:),
            output, sampleBuffer, connection);
    }
}

#pragma mark - 音频回调（直通）
// 注意: 音视频 delegate 用的是同一个 selector
// captureOutput:didOutputSampleBuffer:fromConnection:，
// 上面的实现已经同时服务两者 —— 音频帧不替换，原样转发。

#pragma mark - 造帧



@end
