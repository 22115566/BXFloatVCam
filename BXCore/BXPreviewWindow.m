//
//  BXPreviewWindow.m
//
//  一块可拖动的小窗：AVSampleBufferDisplayLayer 显示解码后的帧，
//  拉流用 BXFFmpegRTSP（独立实例，不影响采集桥的那一路）。
//
//  为什么不用 AVPlayerLayer：
//    RTSP 得自己解，解码出来是 CVPixelBuffer，直接喂给 display layer 延迟最低。
//

#import "BXPreviewWindow.h"
#import "BXFFmpegRTSP.h"
#import "BXStreamVideoSource.h"
#import "BXFloatStore.h"
#import "BXConfig.h"
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>

@interface BXPreviewWindow ()
@property (nonatomic, strong) UIView *box;
@property (nonatomic, strong) AVSampleBufferDisplayLayer *displayLayer;
@property (nonatomic, strong) UILabel *hint;
@property (nonatomic, strong) UIButton *stopButton;
@property (nonatomic, strong) UIView *titleBar;

@property (nonatomic, strong) BXFFmpegRTSP *rtsp;
@property (nonatomic, strong) BXStreamVideoSource *hls;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) id avTimer;
@property (nonatomic, assign) BOOL previewing;
@property (nonatomic, assign) CGSize videoSize;
@property (nonatomic, assign) BOOL gotFrame;
@end

@implementation BXPreviewWindow

+ (instancetype)shared {
    static BXPreviewWindow *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        inst = [[BXPreviewWindow alloc] initWithFrame:CGRectMake(40, 120, 240, 200)];
    });
    return inst;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.windowLevel = UIWindowLevelAlert + 200;
        self.backgroundColor = [UIColor blackColor];
        self.layer.cornerRadius = 14;
        self.clipsToBounds = YES;
        self.hidden = YES;

        UIViewController *vc = [UIViewController new];
        vc.view.backgroundColor = [UIColor blackColor];
        self.rootViewController = vc;

        [self buildUI];
        [self addGestureRecognizer:[[UIPanGestureRecognizer alloc]
                                    initWithTarget:self action:@selector(drag:)]];
    }
    return self;
}

#pragma mark - UI

- (void)buildUI {
    UIView *root = self.rootViewController.view;
    root.backgroundColor = [UIColor blackColor];

    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;

    _displayLayer = [AVSampleBufferDisplayLayer layer];
    _displayLayer.frame = CGRectMake(0, 24, w, h - 24 - 8);
    _displayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    _displayLayer.backgroundColor = [UIColor blackColor].CGColor;
    [root.layer addSublayer:_displayLayer];

    _titleBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 24)];
    _titleBar.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
    [root addSubview:_titleBar];

    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(8, 0, w - 16, 24)];
    t.text = @"RTSP 预览";
    t.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    t.textColor = [UIColor colorWithWhite:0.8 alpha:1];
    [_titleBar addSubview:t];

    _hint = [[UILabel alloc] initWithFrame:CGRectMake(0, h / 2 - 10, w, 20)];
    _hint.text = @"RTSP 连接中…";
    _hint.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _hint.textColor = [UIColor whiteColor];
    _hint.textAlignment = NSTextAlignmentCenter;
    [root addSubview:_hint];

    _stopButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _stopButton.frame = CGRectMake(0, h - 36, w, 36);
    _stopButton.backgroundColor = [UIColor colorWithRed:0.85 green:0.22 blue:0.20 alpha:1];
    _stopButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [_stopButton setTitle:@"停止预览" forState:UIControlStateNormal];
    [_stopButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [_stopButton addTarget:self action:@selector(stopTapped) forControlEvents:UIControlEventTouchUpInside];
    [root addSubview:_stopButton];

    _displayLayer.frame = CGRectMake(0, 24, w, h - 24 - 36 - 6);
}

#pragma mark - 显示/隐藏

- (void)attachToScene {
    if (self.windowScene) return;
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if ([sc isKindOfClass:[UIWindowScene class]]) {
            self.windowScene = (UIWindowScene *)sc;
            break;
        }
    }
}

- (void)showWithURL:(NSString *)url {
    [self attachToScene];
    // 注意：绝不能 makeKeyAndVisible。
    // 预览窗只是叠在宿主 App 之上的一小块浮层，一旦变成 key window，
    // 抖音的窗口失焦，摄像/采集会话会被系统挂起 —— 表现就是「停止预览把拉流打断了」。
    // 这里只让它可见，key window 保持给宿主 App。
    self.hidden = NO;
    self.userInteractionEnabled = YES;
    [self bringSubviewToFront:self];

    [self stopSources];
    _gotFrame = NO;
    _hint.hidden = NO;
    _hint.text = @"RTSP 连接中…";
    [_displayLayer flush];

    if (!url.length) {
        _hint.text = @"没有地址";
        return;
    }

    _previewing = YES;

    if ([url hasPrefix:@"rtsp://"]) {
        _rtsp = [BXFFmpegRTSP new];
        __weak typeof(self) weakSelf = self;
        // 连流本身也是阻塞的，放后台
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSError *e = nil;
            BOOL ok = [weakSelf.rtsp startWithURLString:url error:&e];
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) s = weakSelf;
                if (!s) return;
                if (!ok) {
                    s.hint.text = [NSString stringWithFormat:@"连接失败：%@", e.localizedDescription ?: @"未知"];
                    return;
                }
                [s startTimer];
            });
        });
    } else {
        _hls = [BXStreamVideoSource new];
        NSError *e = nil;
        if (![_hls startWithURLString:url error:&e]) {
            _hint.text = [NSString stringWithFormat:@"连接失败：%@", e.localizedDescription ?: @"未知"];
            return;
        }
        [self startAVTimer];
    }
}

- (void)startTimer {
    [_timer invalidate];
    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 30.0
                                              target:self
                                            selector:@selector(pumpFrame)
                                            userInfo:nil
                                             repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
}

- (void)startAVTimer {
    [_timer invalidate];
    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 30.0
                                              target:self
                                            selector:@selector(pumpHLSFrame)
                                            userInfo:nil
                                             repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
}

#pragma mark - 取帧显示

- (void)pumpFrame {
    if (!_rtsp.isRunning) return;
    CVPixelBufferRef px = [_rtsp copyNextFrameScaledTo:CGSizeZero];
    if (!px) return;
    [self enqueuePixelBuffer:px];
    CVPixelBufferRelease(px);
}

- (void)pumpHLSFrame {
    CVPixelBufferRef px = [_hls copyNextFrameScaledTo:CGSizeZero];
    if (!px) return;
    [self enqueuePixelBuffer:px];
    CVPixelBufferRelease(px);
}

- (void)enqueuePixelBuffer:(CVPixelBufferRef)px {
    CMVideoFormatDescriptionRef fmtDesc = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, px, &fmtDesc) != noErr || !fmtDesc) {
        return;
    }
    CMSampleTimingInfo timing = {
        .duration = CMTimeMake(1, 30),
        .presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock()),
        .decodeTimeStamp = kCMTimeInvalid,
    };
    CMSampleBufferRef sample = NULL;
    if (CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, px, fmtDesc, &timing, &sample) == noErr && sample) {
        if (_displayLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
            [_displayLayer flush];
        }
        [_displayLayer enqueueSampleBuffer:sample];
        CFRelease(sample);
        if (!_gotFrame) {
            _gotFrame = YES;
            _hint.hidden = YES;
            _hint.text = @"";
        }
    }
    CFRelease(fmtDesc);
}

#pragma mark - 交互

- (void)drag:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.superview ?: self];
    if (g.state == UIGestureRecognizerStateChanged) {
        CGRect f = self.frame;
        f.origin.x += t.x;
        f.origin.y += t.y;
        self.frame = f;
        [g setTranslation:CGPointZero inView:self.superview ?: self];
    }
}

- (void)stopTapped {
    [self hidePreview];
}

// 只停预览自己的解码源。这里刻意不碰 BXCaptureBridge —— 那是另一条独立的连接。
- (void)stopSources {
    [_timer invalidate];
    _timer = nil;
    if (_rtsp) { [_rtsp stop]; _rtsp = nil; }
    if (_hls) { [_hls stop]; _hls = nil; }
    [_displayLayer flush];
}

- (void)hidePreview {
    _previewing = NO;
    // 只停预览自己那一路解码，采集桥（正在替换摄像头的拉流）完全不动
    [self stopSources];
    self.hidden = YES;
    NSLog(@"[BXFloat][preview] 停止预览（采集桥的拉流未受影响）");
}

@end
