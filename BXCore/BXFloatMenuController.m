//
//  BXFloatMenuController.m —— 极简稳定版（重写）
//
//  原则：
//    1. 不用 UISwitch / UIScrollView，避免状态回写与重建导致的崩溃。
//    2. 布局只在 viewDidLayoutSubviews 里算 frame，不重建视图。
//    3. 弹窗统一从悬浮窗 rootViewController 出，全部 @try。
//    4. 连流等耗时动作一律后台队列，主线程只改 UI。
//    5. 状态面板显示 启用 / 已解码 / 进入造帧 / 已替换 / 直通 / 造帧 / 错误 / 判定，
//       排查不用再看日志。
//

#import "BXFloatMenuController.h"
#import "BXFloatStore.h"
#import "BXCaptureBridge.h"
#import "BXPreviewWindow.h"
#import "BXConfig.h"

static UIColor *C_BG(void)     { return [UIColor whiteColor]; }
static UIColor *C_TEXT(void)   { return [UIColor colorWithRed:0.11 green:0.11 blue:0.12 alpha:1]; }
static UIColor *C_SUB(void)    { return [UIColor colorWithRed:0.56 green:0.56 blue:0.58 alpha:1]; }
static UIColor *C_CARD(void)   { return [UIColor colorWithRed:0.95 green:0.96 blue:0.97 alpha:1]; }
static UIColor *C_BLUE(void)   { return [UIColor colorWithRed:0.18 green:0.48 blue:1.00 alpha:1]; }
static UIColor *C_BLUEBG(void) { return [UIColor colorWithRed:0.90 green:0.94 blue:1.00 alpha:1]; }
static UIColor *C_GREEN(void)  { return [UIColor colorWithRed:0.20 green:0.72 blue:0.42 alpha:1]; }

@interface BXFloatMenuController () <UIDocumentPickerDelegate>

@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIButton *closeButton;

@property (nonatomic, strong) UIView *statusCard;
@property (nonatomic, strong) UILabel *statusIcon;
@property (nonatomic, strong) UILabel *statusTitle;
@property (nonatomic, strong) UILabel *statusDetail;

@property (nonatomic, strong) UIButton *btnNone;
@property (nonatomic, strong) UIButton *btnLocal;
@property (nonatomic, strong) UIButton *btnRTSP;
@property (nonatomic, strong) UIButton *btnPreview;
@property (nonatomic, strong) UIButton *btnStatus;
@property (nonatomic, strong) UIButton *btnPick;
@property (nonatomic, strong) UIButton *btnURL;

@property (nonatomic, assign) NSInteger source;   // 0 关闭 / 1 本地 / 2 RTSP
@property (nonatomic, assign) BOOL busy;

@end

@implementation BXFloatMenuController

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];
    if (self.view.frame.size.width < 100) {
        self.view.frame = CGRectMake(0, 0, 300, 430);
    }
    self.view.backgroundColor = C_BG();
    self.view.layer.cornerRadius = 18;
    self.view.layer.masksToBounds = YES;

    [self buildUI];
    [self refresh];
}

- (CGFloat)W {
    return self.view.bounds.size.width;
}

#pragma mark - 建 UI

- (void)buildUI {
    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.text = kBXMenuTitle;
    _titleLabel.font = [UIFont systemFontOfSize:21 weight:UIFontWeightBold];
    _titleLabel.textColor = C_TEXT();
    [self.view addSubview:_titleLabel];

    _closeButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _closeButton.backgroundColor = C_BLUE();
    _closeButton.layer.cornerRadius = 17;
    _closeButton.tintColor = [UIColor whiteColor];
    _closeButton.imageEdgeInsets = UIEdgeInsetsMake(9, 9, 9, 9);
    [_closeButton setImage:[UIImage systemImageNamed:@"xmark"] forState:UIControlStateNormal];
    [_closeButton addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_closeButton];

    _statusCard = [[UIView alloc] initWithFrame:CGRectZero];
    _statusCard.backgroundColor = C_CARD();
    _statusCard.layer.cornerRadius = 12;
    [self.view addSubview:_statusCard];

    _statusIcon = [[UILabel alloc] initWithFrame:CGRectZero];
    _statusIcon.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    _statusIcon.textAlignment = NSTextAlignmentCenter;
    [_statusCard addSubview:_statusIcon];

    _statusTitle = [[UILabel alloc] initWithFrame:CGRectZero];
    _statusTitle.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    _statusTitle.textColor = C_TEXT();
    [_statusCard addSubview:_statusTitle];

    _statusDetail = [[UILabel alloc] initWithFrame:CGRectZero];
    _statusDetail.font = [UIFont systemFontOfSize:11];
    _statusDetail.textColor = C_SUB();
    _statusDetail.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [_statusCard addSubview:_statusDetail];

    _btnNone  = [self sourceButton:@"关闭" sub:@"不替换摄像头" tag:0];
    _btnLocal = [self sourceButton:@"本地视频" sub:@"用相册里的视频替换" tag:1];
    _btnRTSP  = [self sourceButton:@"RTSP 拉流" sub:@"用你自己的流替换" tag:2];

    _btnPreview = [self actionButton:@"预览流" tag:10];
    _btnStatus  = [self actionButton:@"运行状态" tag:11];
    _btnPick    = [self actionButton:@"选择视频" tag:12];
    _btnURL     = [self actionButton:@"流地址" tag:13];
}

- (UIButton *)sourceButton:(NSString *)title sub:(NSString *)sub tag:(NSInteger)tag {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.tag = tag;
    b.backgroundColor = C_CARD();
    b.layer.cornerRadius = 12;
    b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    b.titleEdgeInsets = UIEdgeInsetsMake(-9, 14, 9, 0);
    b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:C_TEXT() forState:UIControlStateNormal];
    [b addTarget:self action:@selector(sourceTapped:) forControlEvents:UIControlEventTouchUpInside];

    UILabel *s = [[UILabel alloc] initWithFrame:CGRectZero];
    s.text = sub;
    s.font = [UIFont systemFontOfSize:11];
    s.textColor = C_SUB();
    s.tag = 99;
    s.userInteractionEnabled = NO;
    [b addSubview:s];

    [self.view addSubview:b];
    return b;
}

- (UIButton *)actionButton:(NSString *)title tag:(NSInteger)tag {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.tag = tag;
    b.backgroundColor = C_BLUEBG();
    b.layer.cornerRadius = 12;
    b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:C_BLUE() forState:UIControlStateNormal];
    SEL act = @selector(statusTapped);
    if (tag == 10)      act = @selector(previewTapped);
    else if (tag == 11) act = @selector(statusTapped);
    else if (tag == 12) act = @selector(pickTapped);
    else if (tag == 13) act = @selector(urlTapped);
    [b addTarget:self action:act forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:b];
    return b;
}

#pragma mark - 布局

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = [self W];
    if (w < 100) return;

    CGFloat pad = 16;
    CGFloat cw = w - pad * 2;
    CGFloat y = 16;

    _titleLabel.frame = CGRectMake(pad, y, cw - 46, 28);
    _closeButton.frame = CGRectMake(w - pad - 34, y - 2, 34, 34);
    y += 38;

    _statusCard.frame = CGRectMake(pad, y, cw, 52);
    _statusIcon.frame = CGRectMake(12, 15, 22, 22);
    _statusTitle.frame = CGRectMake(40, 10, cw - 56, 18);
    _statusDetail.frame = CGRectMake(40, 28, cw - 56, 14);
    y += 62;

    NSArray *arr = @[_btnNone, _btnLocal, _btnRTSP];
    for (UIButton *b in arr) {
        b.frame = CGRectMake(pad, y, cw, 52);
        UILabel *sub = [b viewWithTag:99];
        sub.frame = CGRectMake(14, 28, cw - 28, 14);
        y += 58;
    }

    CGFloat half = (cw - 10) / 2.0;
    _btnPreview.frame = CGRectMake(pad, y, half, 42);
    _btnStatus.frame  = CGRectMake(pad + half + 10, y, half, 42);
    y += 50;
    _btnPick.frame    = CGRectMake(pad, y, half, 42);
    _btnURL.frame     = CGRectMake(pad + half + 10, y, half, 42);
}

#pragma mark - 动作

- (BXCaptureBridge *)bridge {
    return [BXCaptureBridge shared];
}

- (NSString *)savedURL {
    NSString *u = [[BXFloatStore shared] objectForKey:@"bx.rtsp.url"];
    return u.length ? u : kBXDefaultStreamURL;
}

- (UIViewController *)hostVC {
    Class wc = NSClassFromString(@"BXFloatWindow");
    if (wc && [wc respondsToSelector:NSSelectorFromString(@"shared")]) {
        id win = [wc performSelector:NSSelectorFromString(@"shared")];
        if ([win isKindOfClass:[UIWindow class]]) {
            UIViewController *vc = [(UIWindow *)win rootViewController];
            while (vc.presentedViewController) vc = vc.presentedViewController;
            if (vc) return vc;
        }
    }
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            if (w.isKeyWindow) {
                UIViewController *vc = w.rootViewController;
                while (vc.presentedViewController) vc = vc.presentedViewController;
                return vc;
            }
        }
    }
    return nil;
}

- (void)alert:(NSString *)title message:(NSString *)msg {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *host = [self hostVC];
        if (!host) {
            NSLog(@"[BXFloat][panel] 无 presenter: %@ %@", title, msg);
            return;
        }
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        @try {
            [host presentViewController:ac animated:YES completion:nil];
        } @catch (NSException *e) {
            NSLog(@"[BXFloat][panel] 弹窗异常 %@", e);
        }
    });
}

- (void)sourceTapped:(UIButton *)b {
    if (self.busy) {
        NSLog(@"[BXFloat][panel] 忙，忽略点击");
        return;
    }
    NSInteger want = b.tag;

    if (want == 0) {
        [self stopEverything];
        self.source = 0;
        [self persist];
        [self refresh];
        return;
    }

    if (want == 1) {
        [self stopNetwork];
        self.source = 1;
        [self persist];
        [self refresh];
        if (self.bridge.sourcePath.length) {
            self.bridge.enabled = YES;
            [[BXFloatStore shared] setObject:@(YES) forKey:@"bx.vcam.enabled"];
            [self refresh];
            // 已有视频时，同时给一次更换入口（点「选择视频」也可以换）
        } else {
            [self presentPicker];
        }
        return;
    }

    [self startRTSP];
}

- (void)startRTSP {
    if (self.busy) return;
    NSString *url = [self savedURL];
    if (!url.length) {
        [self promptURL];
        return;
    }

    self.busy = YES;
    [self refresh];
    NSLog(@"[BXFloat][panel] 开始连流 %@", url);

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;

        NSError *err = nil;
        BOOL ok = NO;
        @try {
            ok = [url hasPrefix:@"rtsp://"]
                ? [s.bridge useRTSPURLString:url error:&err]
                : [s.bridge useStreamURLString:url error:&err];
        } @catch (NSException *e) {
            err = [NSError errorWithDomain:@"BX" code:-1
                                  userInfo:@{NSLocalizedDescriptionKey: e.reason ?: @"异常"}];
        }
        NSLog(@"[BXFloat][panel] 连流结果 ok=%d err=%@", (int)ok, err);

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s2 = weakSelf;
            if (!s2) return;
            s2.busy = NO;
            if (ok) {
                s2.bridge.enabled = YES;
                s2.source = 2;
                [[BXFloatStore shared] setObject:@(YES) forKey:@"bx.vcam.enabled"];
                [[BXFloatStore shared] setObject:@(YES) forKey:@"bx.rtsp.enabled"];
                [[BXFloatStore shared] setObject:url forKey:@"bx.rtsp.url"];
            } else {
                s2.source = 0;
                [[BXFloatStore shared] setObject:@(NO) forKey:@"bx.rtsp.enabled"];
                [s2 alert:@"连接失败" message:err.localizedDescription ?: @"无法连接该地址"];
            }
            [s2 persist];
            [s2 refresh];
        });
    });
}

- (void)promptURL {
    UIViewController *host = [self hostVC];
    if (!host) {
        [self alert:@"打不开输入框" message:@"没有可用的控制器"];
        return;
    }

    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"流地址"
                         message:@"rtsp://ip:554/路径"
                  preferredStyle:UIAlertControllerStyleAlert];
    NSString *cur = [self savedURL];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = cur;
        tf.placeholder = @"rtsp://192.168.1.4:8554/live/123";
        tf.keyboardType = UIKeyboardTypeURL;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"保存并连接" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *a) {
        NSString *u = ac.textFields.firstObject.text ?: @"";
        u = [u stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!u.length) return;
        [[BXFloatStore shared] setObject:u forKey:@"bx.rtsp.url"];
        [weakSelf startRTSP];
    }]];

    @try {
        [host presentViewController:ac animated:YES completion:nil];
    } @catch (NSException *e) {
        NSLog(@"[BXFloat][panel] 输入框异常 %@", e);
    }
}

- (void)presentPicker {
    UIViewController *host = [self hostVC];
    if (!host) {
        [self alert:@"无法选片" message:@"没有可用的控制器"];
        return;
    }
    UIDocumentPickerViewController *p =
        [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.movie"]
                                                             inMode:UIDocumentPickerModeImport];
    p.delegate = self;
    p.allowsMultipleSelection = NO;
    @try {
        [host presentViewController:p animated:YES completion:nil];
    } @catch (NSException *e) {
        NSLog(@"[BXFloat][panel] 选择器异常 %@", e);
    }
}

- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *u = urls.firstObject;
    if (!u) return;
    NSError *e = nil;
    BOOL ok = [self.bridge useVideoAtPath:u.path error:&e];
    NSLog(@"[BXFloat][panel] 选片 %@ -> %@", u.lastPathComponent, ok ? @"成功" : e);
    if (ok) {
        [[BXFloatStore shared] setObject:u.path forKey:@"bx.vcam.path"];
        [[BXFloatStore shared] setObject:@(YES) forKey:@"bx.vcam.enabled"];
        self.bridge.enabled = YES;
        self.source = 1;
        [self persist];
    } else {
        [self alert:@"载入视频失败" message:e.localizedDescription ?: @"未知"];
    }
    [self refresh];
}

- (void)pickTapped {
    [self presentPicker];
}

- (void)urlTapped {
    [self promptURL];
}

- (void)previewTapped {
    NSString *url = self.bridge.rtspURL.length ? self.bridge.rtspURL : [self savedURL];
    @try {
        [[BXPreviewWindow shared] showWithURL:url];
    } @catch (NSException *e) {
        NSLog(@"[BXFloat][panel] 预览异常 %@", e);
    }
}

- (void)statusTapped {
    BXCaptureBridge *b = self.bridge;

    NSString *fmt =
        @"hook：%@\n"
         "启用：%@\n"
         "接管采集：%lu\n"
         "已解码：%lu\n"
         "进入造帧：%lu\n"
         "已替换：%lu\n"
         "直通：%lu\n"
         "造帧：%@\n"
         "错误：%@\n"
         "判定：%@\n"
         "来源：%@";

    NSString *msg = [NSString stringWithFormat:fmt,
        b.installed ? @"已装" : @"未装",
        b.enabled ? @"是" : @"否",
        (unsigned long)b.capturedOutputs,
        (unsigned long)b.decodedFrames,
        (unsigned long)b.attemptFrames,
        (unsigned long)b.replacedFrames,
        (unsigned long)b.passthroughFrames,
        b.streamFrameReason ?: @"-",
        b.buildError ?: @"-",
        b.gateReason ?: @"-",
        b.rtspURL.length ? b.rtspURL : (b.sourcePath ?: @"无")];

    [self alert:@"运行状态" message:msg];
}

- (void)closeTapped {
    // X 只收起面板，不停流。停流请点「关闭」。
    NSLog(@"[BXFloat][panel] X：收起面板（拉流保持）");

    SEL sel = NSSelectorFromString(@"_collapseMenu");
    Class wc = NSClassFromString(@"BXFloatWindow");
    if (wc && [wc respondsToSelector:NSSelectorFromString(@"shared")]) {
        id win = [wc performSelector:NSSelectorFromString(@"shared")];
        if (win && [win respondsToSelector:sel]) {
            [win performSelector:sel];
            return;
        }
    }
    self.view.hidden = YES;
}

#pragma mark - 状态

- (void)stopNetwork {
    @try {
        [self.bridge stopNetworkSources];
    } @catch (NSException *e) {
        NSLog(@"[BXFloat][panel] 停网络异常 %@", e);
    }
}

- (void)stopEverything {
    [self stopNetwork];
    self.bridge.enabled = NO;
    [[BXFloatStore shared] setObject:@(NO) forKey:@"bx.vcam.enabled"];
    [[BXFloatStore shared] setObject:@(NO) forKey:@"bx.rtsp.enabled"];

    @try {
        Class pv = NSClassFromString(@"BXPreviewWindow");
        if (pv) {
            id shared = [pv performSelector:NSSelectorFromString(@"shared")];
            SEL hide = NSSelectorFromString(@"hidePreview");
            if (shared && [shared respondsToSelector:hide]) {
                [shared performSelector:hide];
            }
        }
    } @catch (NSException *e) {
    }
}

- (void)persist {
    NSString *v = (self.source == 2) ? @"rtsp" : (self.source == 1 ? @"local" : @"none");
    [[BXFloatStore shared] setObject:v forKey:@"bx.vcam.source"];
}

- (void)refresh {
    BXCaptureBridge *b = self.bridge;
    NSString *rtsp = b.rtspURL;
    NSString *local = b.sourcePath;

    NSInteger cur = self.source;
    if (rtsp.length) cur = 2;
    else if (b.enabled && local.length) cur = 1;

    NSArray *arr = @[_btnNone, _btnLocal, _btnRTSP];
    for (UIButton *x in arr) {
        BOOL on = (x.tag == cur);
        x.backgroundColor = on ? C_BLUE() : C_CARD();
        [x setTitleColor:(on ? [UIColor whiteColor] : C_TEXT()) forState:UIControlStateNormal];
        UILabel *sub = [x viewWithTag:99];
        sub.textColor = on ? [UIColor colorWithWhite:1 alpha:0.85] : C_SUB();
    }

    if (self.busy) {
        _statusIcon.text = @"⋯";
        _statusIcon.textColor = C_BLUE();
        _statusTitle.text = @"连接中…";
        _statusDetail.text = [self savedURL];
    } else if (cur == 2 && rtsp.length) {
        _statusIcon.text = @"✓";
        _statusIcon.textColor = C_GREEN();
        _statusTitle.text = @"RTSP 已连接";
        _statusDetail.text = rtsp;
    } else if (cur == 1 && local.length) {
        _statusIcon.text = @"✓";
        _statusIcon.textColor = C_GREEN();
        _statusTitle.text = @"本地视频";
        _statusDetail.text = local.lastPathComponent;
    } else {
        _statusIcon.text = @"○";
        _statusIcon.textColor = C_SUB();
        _statusTitle.text = @"未连接";
        _statusDetail.text = [self savedURL];
    }
}

- (void)reload {
    [self refresh];
}

@end
