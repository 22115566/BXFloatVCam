//
//  BXStreamVideoSource.m
//
//  AVPlayer + AVPlayerItemVideoOutput 取帧，输出 BGRA 的 CVPixelBuffer。
//  与 BXVideoSource 的行为对齐：镜像 / 旋转 / 缩放到目标尺寸。
//
//  为什么不用 RTSP：
//    AVFoundation 不支持 RTSP。源头转成 HLS 后延迟约 1~3 秒，够用于直播替换；
//    如果要求 <500ms，只能塞 FFmpeg（重，且 AVFrame 结构体 ABI 不稳定）。
//

#import "BXStreamVideoSource.h"
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>

@interface BXStreamVideoSource ()
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) AVPlayerItemVideoOutput *output;
@property (nonatomic, strong) CIContext *ciContext;
@property (nonatomic, strong) dispatch_queue_t lockQueue;
@property (nonatomic, strong) id timeObserver;
@end

@implementation BXStreamVideoSource {
    CVPixelBufferPoolRef _pool;
    CGSize _poolSize;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lockQueue = dispatch_queue_create("bx.stream.source", DISPATCH_QUEUE_SERIAL);
        _ciContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
        _rotation = 0;
        _mirror = NO;
    }
    return self;
}

- (void)dealloc {
    [self stop];
    if (_pool) { CVPixelBufferPoolRelease(_pool); _pool = NULL; }
}

- (BOOL)isRunning { return self.player != nil; }
- (NSString *)urlString { return _urlString; }

- (BOOL)startWithURLString:(NSString *)urlString error:(NSError **)error {
    [self stop];
    if (!urlString.length) {
        if (error) *error = [NSError errorWithDomain:@"BXStream" code:1
                                            userInfo:@{NSLocalizedDescriptionKey: @"URL 为空"}];
        return NO;
    }
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url || !url.scheme.length) {
        if (error) *error = [NSError errorWithDomain:@"BXStream" code:2
                                            userInfo:@{NSLocalizedDescriptionKey: @"URL 不合法"}];
        return NO;
    }

    _urlString = [urlString copy];

    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
    item.preferredForwardBufferDuration = 0.5;

    NSDictionary *attrs = @{
        kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    _output = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:attrs];
    [_output setSuppressesPlayerRendering:YES];
    if ([item respondsToSelector:@selector(addOutput:)]) {
        [item addOutput:_output];
    }

    _player = [AVPlayer playerWithPlayerItem:item];
    _player.muted = YES;
    _player.automaticallyWaitsToMinimizeStalling = NO;
    _player.actionAtItemEnd = AVPlayerActionAtItemEndNone;

    __weak typeof(self) weakSelf = self;
    _timeObserver = [_player addPeriodicTimeObserverForInterval:CMTimeMake(1, 10)
                                                         queue:dispatch_get_main_queue()
                                                    usingBlock:^(CMTime t) {
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2) return;
        CGSize sz = self2.player.currentItem.presentationSize;
        if (sz.width > 0 && sz.height > 0) self2->_size = sz;
    }];

    [_player play];
    NSLog(@"[BXStream] 开始播放 %@", urlString);
    return YES;
}

- (void)stop {
    if (_timeObserver && _player) {
        [_player removeTimeObserver:_timeObserver];
        _timeObserver = nil;
    }
    [_player pause];
    _player = nil;
    _output = nil;
    _urlString = nil;
    _size = CGSizeZero;
}

#pragma mark - 取帧

- (CVPixelBufferRef)copyNextFrameScaledTo:(CGSize)targetSize CF_RETURNS_RETAINED {
    if (!_player || !_output) return NULL;

    CMTime itemTime = _player.currentItem.currentTime;
    if (!CMTIME_IS_VALID(itemTime)) return NULL;

    if (![_output hasNewPixelBufferForItemTime:itemTime]) return NULL;

    CVPixelBufferRef src = [_output copyPixelBufferForItemTime:itemTime itemTimeForDisplay:NULL];
    if (!src) return NULL;

    CVPixelBufferRef out = [self processFrame:src targetSize:targetSize];
    CVPixelBufferRelease(src);
    return out;
}

- (CVPixelBufferRef)processFrame:(CVPixelBufferRef)src targetSize:(CGSize)targetSize CF_RETURNS_RETAINED {
    size_t w = CVPixelBufferGetWidth(src);
    size_t h = CVPixelBufferGetHeight(src);
    if (w == 0 || h == 0) return NULL;

    BOOL needRotate = (_rotation % 360) != 0;
    BOOL needMirror = _mirror;
    BOOL needScale = !CGSizeEqualToSize(targetSize, CGSizeZero) &&
                     (fabs(targetSize.width - (CGFloat)w) > 1.0 || fabs(targetSize.height - (CGFloat)h) > 1.0);

    if (!needRotate && !needMirror && !needScale) {
        CVPixelBufferRetain(src);
        return src;
    }

    CGSize outSize = needScale ? targetSize : CGSizeMake((CGFloat)w, (CGFloat)h);
    if (_rotation == 90 || _rotation == 270) {
        outSize = CGSizeMake(outSize.height, outSize.width);
    }
    if (outSize.width < 2 || outSize.height < 2) return NULL;

    CIImage *img = [CIImage imageWithCVPixelBuffer:src];

    // 缩放
    if (needScale) {
        CGFloat sx = targetSize.width / (CGFloat)w;
        CGFloat sy = targetSize.height / (CGFloat)h;
        img = [img imageByApplyingTransform:CGAffineTransformMakeScale(sx, sy)];
    }
    // 镜像（X 轴翻转）
    if (needMirror) {
        CGFloat width = needScale ? targetSize.width : (CGFloat)w;
        img = [img imageByApplyingTransform:CGAffineTransformMakeScale(-1, 1)];
        img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(width, 0)];
    }
    // 旋转
    if (needRotate) {
        CGFloat rad = (CGFloat)(_rotation * M_PI / 180.0);
        img = [img imageByApplyingTransform:CGAffineTransformMakeRotation(rad)];
        img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(
            img.extent.origin.x < 0 ? -img.extent.origin.x : 0,
            img.extent.origin.y < 0 ? -img.extent.origin.y : 0)];
    }

    if (!_pool || !CGSizeEqualToSize(_poolSize, outSize)) {
        if (_pool) { CVPixelBufferPoolRelease(_pool); _pool = NULL; }
        NSDictionary *poolAttrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @(outSize.width),
            (id)kCVPixelBufferHeightKey: @(outSize.height),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        };
        CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL,
                                (__bridge CFDictionaryRef)poolAttrs, &_pool);
        _poolSize = outSize;
    }
    if (!_pool) return NULL;

    CVPixelBufferRef dst = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _pool, &dst) != kCVReturnSuccess || !dst) {
        return NULL;
    }
    [_ciContext render:img toCVPixelBuffer:dst bounds:CGRectMake(0, 0, outSize.width, outSize.height)
                 colorSpace:CGColorSpaceCreateDeviceRGB()];
    return dst;
}

@end
