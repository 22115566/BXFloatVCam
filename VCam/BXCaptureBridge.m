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
#import <CoreImage/CoreImage.h>

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

    CMSampleBufferRef replacement = NULL;
    CMSampleBufferRef toSend = sampleBuffer;

    BOOL isVideo = [output isKindOfClass:NSClassFromString(@"AVCaptureVideoDataOutput")];

    // 原来这里只判断 self.source.loaded（本地视频），导致选了 RTSP/HLS 时
    // 根本不会走进替换逻辑 —— 三个来源都要允许。
    BOOL hasAnySource = self.rtsp.isRunning || self.stream.isRunning || self.source.loaded;

    // 记录「为什么没进造帧」，状态面板直接显示，省得反复猜
    if (isVideo) {
        if (!self.enabled)          self.gateReason = @"enabled = NO";
        else if (!hasAnySource)     self.gateReason = @"没有任何可用来源";
        else                        self.gateReason = @"ok";
    }

    if (isVideo && self.enabled && hasAnySource) {
        self.attemptFrames += 1;
        @try {
            replacement = [self _replacementForSampleBuffer:sampleBuffer connection:connection];
        } @catch (NSException *e) {
            NSLog(@"[BXFloat][vcam] 造帧异常 %@", e);
            replacement = NULL;
        }
        if (replacement) {
            toSend = replacement;
            self.replacedFrames += 1;
            if (self.replacedFrames == 1 || self.replacedFrames % 120 == 0) {
                NSLog(@"[BXFloat][vcam] 已替换 %lu 帧 (直通 %lu)",
                      (unsigned long)self.replacedFrames,
                      (unsigned long)self.passthroughFrames);
            }
        }
    }
    if (!replacement && isVideo) {
        self.passthroughFrames += 1;
    }

    id orig = objc_getAssociatedObject(output, kBXOrigDelegateKey);
    if ([orig respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        ((void (*)(id, SEL, id, CMSampleBufferRef, id))objc_msgSend)(
            orig, @selector(captureOutput:didOutputSampleBuffer:fromConnection:),
            output, toSend, connection);
    }

    if (replacement) CFRelease(replacement);
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

- (CMSampleBufferRef)_replacementForSampleBuffer:(CMSampleBufferRef)in
                                      connection:(AVCaptureConnection *)connection {
    CVImageBufferRef camPx = CMSampleBufferGetImageBuffer(in);
    if (!camPx) return NULL;

    CGSize target = CGSizeMake(CVPixelBufferGetWidth(camPx),
                               CVPixelBufferGetHeight(camPx));

    OSType camFmt = CVPixelBufferGetPixelFormatType(camPx);
    static OSType loggedFmt = 0;
    if (loggedFmt != camFmt) {
        loggedFmt = camFmt;
        NSLog(@"[BXFloat][vcam] 摄像头像素格式 = %c%c%c%c",
              (char)(camFmt >> 24), (char)(camFmt >> 16), (char)(camFmt >> 8), (char)camFmt);
    }

    CVPixelBufferRef frame = NULL;
    if (self.rtsp.isRunning) {
        frame = [self.rtsp copyNextFrameScaledTo:target];
    } else if (self.stream.isRunning) {
        frame = [self.stream copyNextFrameScaledTo:target];
    } else {
        frame = [self.source copyNextFrameScaledTo:target];
    }
    // 转换到摄像头用的像素格式（通常是 420f），让后面的格式描述能复用、处理链也认
    OSType camPixelFmt = CVPixelBufferGetPixelFormatType(camPx);
    CVPixelBufferRef converted = BXConvertPixelBuffer(frame, camPixelFmt);
    if (converted) {
        CVPixelBufferRelease(frame);
        frame = converted;
        self.buildError = [NSString stringWithFormat:@"转换ok %c%c%c%c",
                           (char)(camPixelFmt >> 24), (char)(camPixelFmt >> 16),
                           (char)(camPixelFmt >> 8), (char)camPixelFmt];
    } else {
        self.buildError = @"像素格式转换失败";
        NSLog(@"[BXFloat][vcam] 像素格式转换失败 camFmt=%08x", (unsigned)camPixelFmt);
    }

    if (!frame) {
        static NSUInteger nullCount = 0;
        nullCount++;
        if (nullCount % 60 == 1) {
            NSLog(@"[BXFloat][vcam] 取帧为空（累计 %lu），本轮直通", (unsigned long)nullCount);
        }
        return NULL;
    }

    /*
     崩溃原因（Aweme-2026-10-31-170141.ips）：
       *** CFRelease() called with NULL ***   EXC_BREAKPOINT
       调用栈：BXCaptureBridge captureOutput: → AwemeCore → CFRelease
     抖音拿到帧后会去读 format description 的扩展字段和 sample buffer 的 attachments，
     读到 NULL 之后直接 CFRelease —— 系统就断言了。
     所以这里必须「沿用原帧的 format description 与 attachments」，
     只替换图像内容，不要造一个干干净净的新 buffer。
     */

    // 1) 复用原 format description —— 但必须「尺寸 + 像素格式」都一致。
    //    摄像头一般是 420f（YUV），我们造的是 BGRA；把 420f 的 format description
    //    套在 BGRA 缓冲上，CMSampleBufferCreateReadyWithImageBuffer 会直接校验失败返回 NULL，
    //    表现就是「进入造帧很多次、已替换永远是 0」。
    CMFormatDescriptionRef origFmt = CMSampleBufferGetFormatDescription(in);
    CMFormatDescriptionRef fmt = NULL;

    size_t fw = CVPixelBufferGetWidth(frame);
    size_t fh = CVPixelBufferGetHeight(frame);
    OSType frameFmt = CVPixelBufferGetPixelFormatType(frame);

    BOOL canReuse = NO;
    if (origFmt) {
        CMVideoDimensions d = CMVideoFormatDescriptionGetDimensions(origFmt);
        OSType origSub = CMFormatDescriptionGetMediaSubType(origFmt);
        canReuse = ((size_t)d.width == fw &&
                    (size_t)d.height == fh &&
                    origSub == frameFmt);
        static OSType loggedSub = 0;
        if (loggedSub != origSub) {
            loggedSub = origSub;
            NSLog(@"[BXFloat][vcam] 摄像头 format subtype=%c%c%c%c 我们的帧=%c%c%c%c",
                  (char)(origSub >> 24), (char)(origSub >> 16), (char)(origSub >> 8), (char)origSub,
                  (char)(frameFmt >> 24), (char)(frameFmt >> 16), (char)(frameFmt >> 8), (char)frameFmt);
        }
    }

    if (canReuse) {
        fmt = (CMFormatDescriptionRef)CFRetain(origFmt);
    } else {
        OSStatus fe = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, frame, &fmt);
        if (fe != noErr || !fmt) {
            self.buildError = [NSString stringWithFormat:@"建fmt失败 st=%d", (int)fe];
            NSLog(@"[BXFloat][vcam] 建 format description 失败 %d", (int)fe);
            CVPixelBufferRelease(frame);
            return NULL;
        }
    }
    if (!fmt) {
        CVPixelBufferRelease(frame);
        return NULL;
    }

    // 2) 时间戳沿用原帧
    CMSampleTimingInfo timing;
    if (CMSampleBufferGetSampleTimingInfo(in, 0, &timing) != noErr) {
        timing = (CMSampleTimingInfo){
            .duration = CMTimeMake(1, 30),
            .presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock()),
            .decodeTimeStamp = kCMTimeInvalid,
        };
    }

    CMSampleBufferRef out = NULL;
    OSStatus st = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, frame, fmt, &timing, &out);
    CFRelease(fmt);
    CVPixelBufferRelease(frame);
    if (st != noErr || !out) {
        static int logCount = 0;
        self.buildError = [NSString stringWithFormat:@"建buffer失败 st=%d %zux%zu",
                           (int)st, fw, fh];
        if (logCount < 5) {
            logCount++;
            NSLog(@"[BXFloat][vcam] CMSampleBufferCreateReadyWithImageBuffer 失败 st=%d fmt=%c%c%c%c %zux%zu",
                  (int)st,
                  (char)(frameFmt >> 24), (char)(frameFmt >> 16), (char)(frameFmt >> 8), (char)frameFmt,
                  fw, fh);
        }
        return NULL;
    }

    // 3) 把原帧的 attachments 全部复制过来（这是崩溃的直接修复点）
    CFDictionaryRef atts = CMCopyDictionaryOfAttachments(kCFAllocatorDefault, in,
                                                         kCMAttachmentMode_ShouldPropagate);
    if (atts) {
        CMSetAttachments(out, atts, kCMAttachmentMode_ShouldPropagate);
        CFRelease(atts);
    }

    self.buildError = @"成功";
    return out;
}

@end
