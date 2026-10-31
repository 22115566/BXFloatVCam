//
//  BXFloatMenuController.m —— 百相风格面板（含快捷调整）
//
//  布局对照百相 0.20.33：
//    标题 + 蓝色圆形 X
//    状态条（连接状态 / 地址）
//    替换来源：关闭 / 本地视频 / RTSP 拉流
//    快捷调整：镜像 / 旋转 / 声音来源（点击循环切换）
//    底部动作：预览流 / 运行状态 / 选择视频 / 流地址
//
//  稳定性约定：
//    · 不用 UISwitch、不用 UIScrollView，全部固定 frame
//    · 布局只在 viewDidLayoutSubviews 里算，不重建视图
//    · 弹窗统一从悬浮窗 rootViewController 出，全部 @try
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
@property (nonatomic, strong) UIButton *btnAddr;   // 状态条右侧的「地址」快捷入口
@property (nonatomic, strong) UILabel *footerLabel;

@property (nonatomic, strong) UIButton *btnNone;
@property (nonatomic, strong) UIButton *btnLocal;
@property (nonatomic, strong) UIButton *btnRTSP;

@property (nonatomic, strong) UILabel *quickLabel;
@property (nonatomic, strong) UIView *tileMirror;
@property (nonatomic, strong) UIView *tileRotate;
@property (nonatomic, strong) UIView *tileAudio;

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

- (CGFloat)W { return self.view.bounds.size.width; }

#pragma mark - 建 UI

- (void)buildUI {
    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.text = kBXMenuTitle;
    _titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    _titleLabel.textColor = C_TEXT();
    [self.view addSubview:_titleLabel];

    _closeButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _closeButton.backgroundColor = C_BLUE();
    _closeButton.layer.cornerRadius = 16;
    _closeButton.tintColor = [UIColor whiteColor];
    _closeButton.imageEdgeInsets = UIEdgeInsetsMake(8, 8, 8, 8);
    [_closeButton setImage:[UIImage systemImageNamed:@"xmark"] forState:UIControlStateNormal];
    [_closeButton addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_closeButton];

    _statusCard = [[UIView alloc] initWithFrame:CGRectZero];
    _statusCard.backgroundColor = C_CARD();
    _statusCard.layer.cornerRadius = 10;
    [self.view addSubview:_statusCard];

    _statusIcon = [[UILabel alloc] initWithFrame:CGRectZero];
    _statusIcon.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    _statusIcon.textAlignment = NSTextAlignmentCenter;
    [_statusCard addSubview:_statusIcon];

    _statusTitle = [[UILabel alloc] initWithFrame:CGRectZero];
    _statusTitle.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    _statusTitle.textColor = C_TEXT();
    [_statusCard addSubview:_statusTitle];

    _statusDetail = [[UILabel alloc] initWithFrame:CGRectZero];
    _statusDetail.font = [UIFont systemFontOfSize:10];
    _statusDetail.textColor = C_SUB();
    _statusDetail.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [_statusCard addSubview:_statusDetail];

    _btnAddr = [UIButton buttonWithType:UIButtonTypeSystem];
    _btnAddr.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    [_btnAddr setTitle:@"地址" forState:UIControlStateNormal];
    [_btnAddr setTitleColor:C_BLUE() forState:UIControlStateNormal];
    [_btnAddr addTarget:self action:@selector(urlTapped) forControlEvents:UIControlEventTouchUpInside];
    [_statusCard addSubview:_btnAddr];

    _btnNone  = [self sourceButton:@"关闭" sub:@"不替换摄像头" tag:0];
    _btnLocal = [self sourceButton:@"本地视频" sub:@"用相册里的视频替换" tag:1];
    _btnRTSP  = [self sourceButton:@"RTSP 拉流" sub:@"用你自己的流替换" tag:2];

    _quickLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _quickLabel.text = @"快捷调整";
    _quickLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    _quickLabel.textColor = C_SUB();
    [self.view addSubview:_quickLabel];

    _tileMirror = [self tileWithIcon:@"arrow.left.and.right.square" title:@"镜像"];
    _tileRotate = [self tileWithIcon:@"rotate.right" title:@"旋转"];
    _tileAudio  = [self tileWithIcon:@"speaker.wave.2.fill" title:@"声音来源"];

    _tileMirror.tag = 20;
    _tileRotate.tag = 21;
    _tileAudio.tag  = 22;
    for (UIView *t in @[_tileMirror, _tileRotate, _tileAudio]) {
        [t addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self
                                                                     action:@selector(tileTapped:)]];
    }

    _btnPreview = [self actionButton:@"预览流" tag:10];
    _btnStatus  = [self actionButton:@"运行状态" tag:11];
    _btnPick    = [self actionButton:@"选择视频" tag:12];
    _btnURL     = [self actionButton:@"流地址" tag:13];

    _footerLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _footerLabel.font = [UIFont systemFontOfSize:9];
    _footerLabel.textColor = C_SUB();
    _footerLabel.textAlignment = NSTextAlignmentCenter;
    _footerLabel.text = [NSString stringWithFormat:@"%@ %@ · local 版（无授权）", kBXMenuTitle, kBXVersion];
    [self.view addSubview:_footerLabel];
}

- (UIButton *)sourceButton:(NSString *)title sub:(NSString *)sub tag:(NSInteger)tag {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.tag = tag;
    b.backgroundColor = C_CARD();
    b.layer.cornerRadius = 10;
    b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    b.titleEdgeInsets = UIEdgeInsetsMake(-8, 12, 8, 0);
    b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:C_TEXT() forState:UIControlStateNormal];
    [b addTarget:self action:@selector(sourceTapped:) forControlEvents:UIControlEventTouchUpInside];

    UILabel *s = [[UILabel alloc] initWithFrame:CGRectZero];
    s.text = sub;
    s.font = [UIFont systemFontOfSize:10];
    s.textColor = C_SUB();
    s.tag = 99;
    s.userInteractionEnabled = NO;
    [b addSubview:s];

    [self.view addSubview:b];
    return b;
}

- (UIView *)tileWithIcon:(NSString *)icon title:(NSString *)title {
    UIView *t = [[UIView alloc] initWithFrame:CGRectZero];
    t.backgroundColor = C_BLUEBG();
    t.layer.cornerRadius = 10;
    t.userInteractionEnabled = YES;
    [self.view addSubview:t];

    UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectZero];
    iv.image = [UIImage systemImageNamed:icon];
    iv.tintColor = C_BLUE();
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.tag = 101;
    [t addSubview:iv];

    UILabel *name = [[UILabel alloc] initWithFrame:CGRectZero];
    name.text = title;
    name.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    name.textColor = C_TEXT();
    name.tag = 102;
    [t addSubview:name];

    UILabel *val = [[UILabel alloc] initWithFrame:CGRectZero];
    val.font = [UIFont systemFontOfSize:10];
    val.textColor = C_SUB();
    val.tag = 103;
    [t addSubview:val];

    return t;
}

- (UIButton *)actionButton:(NSString *)title tag:(NSInteger)tag {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.tag = tag;
    b.backgroundColor = C_CARD();
    b.layer.cornerRadius = 10;
    b.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:C_TEXT() forState:UIControlStateNormal];

    SEL act = @selector(statusTapped);
    if (tag == 10)      act = @selector(previewTapped);
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

    CGFloat pad = 14;
    CGFloat cw = w - pad * 2;
    CGFloat y = 10;

    _titleLabel.frame = CGRectMake(pad, y, cw - 44, 24);
    _closeButton.frame = CGRectMake(w - pad - 30, y - 2, 30, 30);
    y += 32;

    _statusCard.frame = CGRectMake(pad, y, cw, 44);
    _statusIcon.frame = CGRectMake(10, 12, 20, 20);
    _statusTitle.frame = CGRectMake(36, 7, cw - 106, 16);
    _statusDetail.frame = CGRectMake(36, 23, cw - 106, 14);
    _btnAddr.frame = CGRectMake(cw - 60, 7, 50, 30);
    y += 52;

    for (UIButton *b in @[_btnNone, _btnLocal, _btnRTSP]) {
        b.frame = CGRectMake(pad, y, cw, 42);
        UILabel *sub = [b viewWithTag:99];
        sub.frame = CGRectMake(12, 23, cw - 24, 12);
        y += 46;
    }

    y += 2;
    _quickLabel.frame = CGRectMake(pad, y, cw, 13);
    y += 18;

    CGFloat gap = 8;
    CGFloat tw = (cw - gap * 2) / 3.0;
    NSArray *tiles = @[_tileMirror, _tileRotate, _tileAudio];
    for (NSInteger i = 0; i < 3; i++) {
        UIView *t = tiles[i];
        t.frame = CGRectMake(pad + i * (tw + gap), y, tw, 58);
        UIImageView *iv = [t viewWithTag:101];
        UILabel *name = [t viewWithTag:102];
        UILabel *val = [t viewWithTag:103];
        iv.frame = CGRectMake(8, 7, 16, 16);
        name.frame = CGRectMake(8, 26, tw - 16, 13);
        val.frame = CGRectMake(8, 40, tw - 16, 12);
    }
    y += 62;

    CGFloat half = (cw - gap) / 2.0;
    _btnPreview.frame = CGRectMake(pad, y, half, 36);
    _btnStatus.frame  = CGRectMake(pad + half + gap, y, half, 36);
    y += 42;
    _btnPick.frame    = CGRectMake(pad, y, half, 36);
    _btnURL.frame     = CGRectMake(pad + half + gap, y, half, 36);
    y += 42;

    _footerLabel.frame = CGRectMake(pad, y, cw, 14);
}

#pragma mark - 动作

- (BXCaptureBridge *)bridge { return [BXCaptureBridge shared]; }

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
        NSLog(@"[BXFloat][panel] 忙，忽略");
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
        if (!self.bridge.sourcePath.length) {
            [self refresh];
            [self presentPicker];
            return;
        }
        self.bridge.enabled = YES;
        [[BXFloatStore shared] setObject:@(YES) forKey:@"bx.vcam.enabled"];
        [self refresh];
        return;
    }

    [self startRTSP];
}

- (void)tileTapped:(UITapGestureRecognizer *)g {
    BXCaptureBridge *b = self.bridge;
    BXFloatStore *st = [BXFloatStore shared];

    if (g.view.tag == 20) {
        b.mirror = !b.mirror;
        [st setObject:@(b.mirror) forKey:@"bx.vcam.mirror"];
    } else if (g.view.tag == 21) {
        NSInteger r = (b.rotation + 90) % 360;
        b.rotation = r;
        [st setObject:@(r / 90) forKey:@"bx.vcam.rotation"];
    } else if (g.view.tag == 22) {
        b.audioReplace = !b.audioReplace;
        [st setObject:@(b.audioReplace) forKey:@"bx.vcam.audio"];
    }
    [self refresh];
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
        NSLog(@"[BXFloat][panel] 连流 ok=%d err=%@", (int)ok, err);

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

- (void)pickTapped { [self presentPicker]; }
- (void)urlTapped  { [self promptURL]; }

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
         "音频替换：%lu\n"
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
        (unsigned long)b.audioReplaced,
        (unsigned long)b.passthroughFrames,
        b.streamFrameReason ?: @"-",
        b.buildError ?: @"-",
        b.gateReason ?: @"-",
        b.rtspURL.length ? b.rtspURL : (b.sourcePath ?: @"无")];

    [self alert:@"运行状态" message:msg];
}

- (void)closeTapped {
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
            if (shared && [shared respondsToSelector:hide]) [shared performSelector:hide];
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

    for (UIButton *x in @[_btnNone, _btnLocal, _btnRTSP]) {
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
        _statusDetail.text = [NSString stringWithFormat:@"%@ · 已替换 %lu 帧",
                              rtsp, (unsigned long)b.replacedFrames];
    } else if (cur == 1 && local.length) {
        _statusIcon.text = @"✓";
        _statusIcon.textColor = C_GREEN();
        _statusTitle.text = @"本地视频";
        _statusDetail.text = local.lastPathComponent;
    } else {
        _statusIcon.text = @"○";
        _statusIcon.textColor = C_SUB();
        _statusTitle.text = @"未连接";
        _statusDetail.text = [self savedURL].length
            ? [self savedURL]
            : @"先点「地址」填一个 rtsp:// 地址";
    }

    UILabel *vm = [_tileMirror viewWithTag:103];
    UILabel *vr = [_tileRotate viewWithTag:103];
    UILabel *va = [_tileAudio viewWithTag:103];
    vm.text = b.mirror ? @"开启" : @"关闭";
    vr.text = [NSString stringWithFormat:@"%ld°", (long)b.rotation];
    va.text = b.audioReplace ? @"视频原声" : @"麦克风";

    _tileMirror.backgroundColor = b.mirror ? C_BLUEBG() : C_CARD();
    _tileRotate.backgroundColor = (b.rotation != 0) ? C_BLUEBG() : C_CARD();
    _tileAudio.backgroundColor  = b.audioReplace ? C_BLUEBG() : C_CARD();
}

- (void)reload {
    [self refresh];
}

@end
