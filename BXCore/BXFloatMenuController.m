//
//  BXFloatMenuController.m —— 百相风格面板（v2）
//
//  视觉对齐百相 0.20.33：
//    白色圆角卡片 · 标题 + 蓝色圆形关闭按钮 · 状态条 · 三段式来源选择
//    大号主按钮 · 「快捷调整」两列磁贴 · 底部版本小字
//
//  关键修复（v1 的 bug）：
//    连流 avformat_open_input 是阻塞调用，v1 在主线程里直接调 → 整个界面卡死。
//    现在全部丢到全局队列，主线程只负责把按钮切成「连接中…」，界面始终可点。
//

#import "BXFloatMenuController.h"
#import "BXFloatStore.h"
#import "BXCaptureBridge.h"
#import "BXConfig.h"
#import "BXPreviewWindow.h"
#import <QuartzCore/QuartzCore.h>

#pragma mark - 配色

static UIColor *C_BG(void)       { return [UIColor whiteColor]; }
static UIColor *C_TEXT(void)     { return [UIColor colorWithRed:0.11 green:0.11 blue:0.12 alpha:1]; }
static UIColor *C_SUB(void)      { return [UIColor colorWithRed:0.56 green:0.56 blue:0.58 alpha:1]; }
static UIColor *C_CARD(void)     { return [UIColor colorWithRed:0.95 green:0.96 blue:0.97 alpha:1]; }
static UIColor *C_ACCENT(void)   { return [UIColor colorWithRed:0.18 green:0.48 blue:1.00 alpha:1]; }
static UIColor *C_ACCENT_BG(void){ return [UIColor colorWithRed:0.90 green:0.94 blue:1.00 alpha:1]; }
static UIColor *C_GREEN(void)    { return [UIColor colorWithRed:0.20 green:0.72 blue:0.42 alpha:1]; }

typedef NS_ENUM(NSInteger, BXSourceKind) { BXSourceNone = 0, BXSourceLocal, BXSourceRTSP };

@interface BXFloatMenuController () <UIDocumentPickerDelegate>
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIView *content;
@property (nonatomic, assign) CGFloat cursor;      // 纵向排版游标

@property (nonatomic, strong) UILabel *statusIcon;
@property (nonatomic, strong) UILabel *statusTitle;
@property (nonatomic, strong) UILabel *statusDetail;
@property (nonatomic, strong) UIButton *statusAction;

@property (nonatomic, strong) NSMutableArray<UIButton *> *segButtons;   // 已废弃，保留避免改动过多
@property (nonatomic, strong) UISwitch *swNone;
@property (nonatomic, strong) UISwitch *swLocal;
@property (nonatomic, strong) UISwitch *swRTSP;
@property (nonatomic, assign) BOOL updatingUI;
@property (nonatomic, assign) BXSourceKind source;

@property (nonatomic, strong) UIButton *primary;
@property (nonatomic, assign) BOOL connecting;

@property (nonatomic, strong) NSMutableArray<UIView *> *tiles;
@property (nonatomic, strong) NSMutableArray<UILabel *> *tileValues;

@property (nonatomic, strong) UIDocumentPickerViewController *picker;
@property (nonatomic, assign) CGFloat builtWidth;
@end

@implementation BXFloatMenuController

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];
    // 窗口会在展开时设置 frame；这里先给一个默认尺寸，避免用 0 宽排版
    if (self.view.frame.size.width < 100) {
        self.view.frame = CGRectMake(0, 0, 300, 430);
    }
    self.view.backgroundColor = C_BG();
    self.view.layer.cornerRadius = 18;
    self.view.layer.masksToBounds = YES;

    [self buildAll];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = self.view.bounds.size.width;
    if (w > 100 && fabs(w - self.builtWidth) > 0.5) {
        [self buildAll];      // 宽度变了（窗口展开时给的尺寸），整体重排
    }
}

- (void)buildAll {
    for (UIView *v in self.view.subviews) {
        if (v != _scroll) [v removeFromSuperview];
    }
    [_scroll removeFromSuperview];
    _scroll = nil;
    _content = nil;
    [_segButtons removeAllObjects];
    [_tiles removeAllObjects];
    [_tileValues removeAllObjects];
    _segButtons = [NSMutableArray array];
    _tiles = [NSMutableArray array];
    _tileValues = [NSMutableArray array];

    _builtWidth = self.view.bounds.size.width;
    _source = [self loadSource];
    _cursor = 6;

    [self buildScroll];
    [self buildHeader];
    [self buildStatus];
    [self buildSourceSegment];
    [self buildPrimary];
    [self buildQuickSection];
    [self buildFooter];
    [self finishLayout];
    [self reload];
}


- (CGFloat)W { return self.view.bounds.size.width; }
- (CGFloat)pad { return 16; }

#pragma mark - 骨架

- (void)buildScroll {
    _scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scroll.alwaysBounceVertical = YES;
    _scroll.showsVerticalScrollIndicator = NO;
    [self.view addSubview:_scroll];

    _content = [[UIView alloc] initWithFrame:CGRectMake(0, 0, [self W], 400)];
    _content.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_scroll addSubview:_content];
}

// 放一个满宽视图，纵向游标下移
- (void)addFullWidth:(UIView *)v height:(CGFloat)h gap:(CGFloat)gap {
    v.frame = CGRectMake([self pad], _cursor + gap, [self W] - [self pad] * 2, h);
    v.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_content addSubview:v];
    _cursor = CGRectGetMaxY(v.frame);
}

- (void)finishLayout {
    _content.frame = CGRectMake(0, 0, [self W], _cursor + 20);
    _scroll.contentSize = _content.frame.size;
}

#pragma mark - 头部

- (void)buildHeader {
    UIView *head = [[UIView alloc] initWithFrame:CGRectMake([self pad], _cursor, [self W] - [self pad] * 2, 34)];
    head.backgroundColor = [UIColor clearColor];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, [self W] - 90, 30)];
    title.text = kBXMenuTitle;
    title.font = [UIFont systemFontOfSize:21 weight:UIFontWeightBold];
    title.textColor = C_TEXT();
    [head addSubview:title];

    CGFloat bs = 34;
    UIButton *close = [UIButton buttonWithType:UIButtonTypeCustom];
    close.frame = CGRectMake([self W] - [self pad] * 2 - bs, -2, bs, bs);
    close.backgroundColor = C_ACCENT();
    close.layer.cornerRadius = bs / 2.0;
    close.tintColor = [UIColor whiteColor];
    close.imageEdgeInsets = UIEdgeInsetsMake(9, 9, 9, 9);
    [close setImage:[UIImage systemImageNamed:@"xmark"] forState:UIControlStateNormal];
    [close addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    head.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    close.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [head addSubview:close];

    [_content addSubview:head];
    _cursor = CGRectGetMaxY(head.frame) + 8;
}

#pragma mark - 状态条

- (void)buildStatus {
    UIView *bar = [[UIView alloc] initWithFrame:CGRectZero];
    bar.backgroundColor = C_CARD();
    bar.layer.cornerRadius = 12;

    _statusIcon = [[UILabel alloc] initWithFrame:CGRectMake(12, 15, 22, 22)];
    _statusIcon.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    _statusIcon.textColor = C_SUB();
    _statusIcon.textAlignment = NSTextAlignmentCenter;
    _statusIcon.text = @"○";
    [bar addSubview:_statusIcon];

    _statusTitle = [[UILabel alloc] initWithFrame:CGRectMake(40, 10, [self W] - [self pad] * 2 - 130, 18)];
    _statusTitle.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    _statusTitle.textColor = C_TEXT();
    [bar addSubview:_statusTitle];

    _statusDetail = [[UILabel alloc] initWithFrame:CGRectMake(40, 28, [self W] - [self pad] * 2 - 130, 14)];
    _statusDetail.font = [UIFont systemFontOfSize:11];
    _statusDetail.textColor = C_SUB();
    _statusDetail.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [bar addSubview:_statusDetail];

    _statusAction = [UIButton buttonWithType:UIButtonTypeSystem];
    _statusAction.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    [_statusAction setTitle:@"地址" forState:UIControlStateNormal];
    _statusAction.frame = CGRectMake([self W] - [self pad] * 2 - 70, 11, 60, 30);
    _statusAction.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [_statusAction addTarget:self action:@selector(editURLTapped) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:_statusAction];

    [self addFullWidth:bar height:52 gap:10];
}

#pragma mark - 来源三段

- (void)buildSourceSegment {
    UILabel *sec = [[UILabel alloc] initWithFrame:CGRectZero];
    sec.text = @"替换来源";
    sec.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    sec.textColor = C_SUB();
    [self addFullWidth:sec height:16 gap:14];

    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.backgroundColor = C_CARD();
    card.layer.cornerRadius = 12;

    CGFloat innerW = [self W] - [self pad] * 2;
    NSArray *titles = @[@"关闭", @"本地视频", @"RTSP 拉流"];
    NSArray *subs = @[@"不替换摄像头", @"用相册里的视频替换", @"用网络流替换"];
    NSMutableArray *sws = [NSMutableArray array];

    for (NSInteger k = 0; k < 3; k++) {
        CGFloat y = 6 + k * 52;

        UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(14, y + 6, innerW - 90, 18)];
        name.text = titles[k];
        name.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        name.textColor = C_TEXT();
        [card addSubview:name];

        UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(14, y + 24, innerW - 90, 14)];
        sub.text = subs[k];
        sub.font = [UIFont systemFontOfSize:11];
        sub.textColor = C_SUB();
        [card addSubview:sub];

        UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(innerW - 65, y + 12, 51, 31)];
        sw.tag = k;
        sw.onTintColor = C_ACCENT();
        sw.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        [sw addTarget:self action:@selector(swChanged:) forControlEvents:UIControlEventValueChanged];
        [card addSubview:sw];
        [sws addObject:sw];

        if (k < 2) {
            UIView *line = [[UIView alloc] initWithFrame:CGRectMake(14, y + 47, innerW - 28, 0.5)];
            line.backgroundColor = [UIColor colorWithWhite:0 alpha:0.06];
            [card addSubview:line];
        }
    }

    self.swNone = sws[0];
    self.swLocal = sws[1];
    self.swRTSP = sws[2];

    [self addFullWidth:card height:6 + 3 * 52 gap:8];
}

#pragma mark - 主按钮

- (void)buildPrimary {
    _primary = [UIButton buttonWithType:UIButtonTypeCustom];
    _primary.layer.cornerRadius = 12;
    _primary.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [_primary addTarget:self action:@selector(primaryTapped) forControlEvents:UIControlEventTouchUpInside];
    [self addFullWidth:_primary height:50 gap:14];
}

#pragma mark - 快捷调整

- (void)buildQuickSection {
    UILabel *sec = [[UILabel alloc] initWithFrame:CGRectZero];
    sec.text = @"快捷调整";
    sec.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    sec.textColor = C_SUB();
    [self addFullWidth:sec height:16 gap:16];

    CGFloat gap = 10;
    CGFloat innerW = [self W] - [self pad] * 2;
    CGFloat tw = (innerW - gap) / 2.0;
    NSArray *items = @[
        @[@"arrow.left.and.right.righttriangle.left.righttriangle.right", @"镜像"],
        @[@"rotate.right", @"旋转"],
        @[@"play.rectangle", @"预览"],
        @[@"film", @"选择视频"],
        @[@"waveform.path.ecg", @"运行状态"],
    ];

    CGFloat gridTop = _cursor + 8;
    for (NSInteger i = 0; i < items.count; i++) {
        UIView *t = [self tileWithIcon:items[i][0] title:items[i][1] tag:i width:tw];
        t.frame = CGRectMake([self pad] + (i % 2) * (tw + gap),
                             gridTop + (i / 2) * (74 + gap), tw, 74);
        t.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [_content addSubview:t];
        [_tiles addObject:t];
    }
    NSInteger rows = (items.count + 1) / 2;
    _cursor = gridTop + rows * 74 + (rows - 1) * gap;
}

- (UIView *)tileWithIcon:(NSString *)icon title:(NSString *)title tag:(NSInteger)tag width:(CGFloat)w {
    UIView *t = [[UIView alloc] initWithFrame:CGRectZero];
    t.backgroundColor = C_ACCENT_BG();
    t.layer.cornerRadius = 12;
    t.tag = tag;
    t.userInteractionEnabled = YES;
    [t addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tileTapped:)]];

    UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(12, 14, 20, 20)];
    iv.image = [UIImage systemImageNamed:icon];
    iv.tintColor = C_ACCENT();
    iv.contentMode = UIViewContentModeScaleAspectFit;
    [t addSubview:iv];

    UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(12, 38, w - 24, 16)];
    name.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    name.textColor = C_TEXT();
    name.text = title;
    [t addSubview:name];

    UILabel *val = [[UILabel alloc] initWithFrame:CGRectMake(12, 54, w - 24, 14)];
    val.font = [UIFont systemFontOfSize:11];
    val.textColor = C_SUB();
    [t addSubview:val];
    [_tileValues addObject:val];
    return t;
}

#pragma mark - 底部

- (void)buildFooter {
    UILabel *f = [[UILabel alloc] initWithFrame:CGRectZero];
    f.font = [UIFont systemFontOfSize:10];
    f.textColor = C_SUB();
    f.textAlignment = NSTextAlignmentCenter;
    f.text = [NSString stringWithFormat:@"%@ %@ · local", kBXMenuTitle, kBXVersion];
    [self addFullWidth:f height:16 gap:18];
}

#pragma mark - 行为

- (BXCaptureBridge *)bridge { return [BXCaptureBridge shared]; }

- (NSString *)savedURL {
    NSString *u = [[BXFloatStore shared] objectForKey:@"bx.rtsp.url"];
    return u.length ? u : kBXDefaultStreamURL;
}

- (BXSourceKind)loadSource {
    NSString *v = [[BXFloatStore shared] objectForKey:@"bx.vcam.source"];
    if ([v isEqualToString:@"rtsp"]) return BXSourceRTSP;
    if ([v isEqualToString:@"local"]) return BXSourceLocal;
    return BXSourceNone;
}

- (void)persistSource {
    NSString *v = (self.source == BXSourceRTSP) ? @"rtsp"
                 : (self.source == BXSourceLocal) ? @"local" : @"none";
    [[BXFloatStore shared] setObject:v forKey:@"bx.vcam.source"];
}

- (UIViewController *)topMost {
    UIViewController *top = self;
    while (top.presentedViewController) top = top.presentedViewController;
    return top;
}

- (void)closeTapped {
    // 关闭 = 停掉一切：断流、关替换、关预览，然后收起面板
    NSLog(@"[BXFloat][panel] 关闭：停止拉流");
    [self stopAll];
    [self persistSource];

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
        NSLog(@"[BXFloat][panel] 关预览异常 %@", e);
    }

    [self reload];

    // 交给悬浮窗收起，保持它内部的展开/收起状态一致
    SEL sel = NSSelectorFromString(@"_collapseMenu");
    Class winCls = NSClassFromString(@"BXFloatWindow");
    if (winCls && [winCls respondsToSelector:NSSelectorFromString(@"shared")]) {
        id shared = [winCls performSelector:NSSelectorFromString(@"shared")];
        if (shared && [shared respondsToSelector:sel]) {
            [shared performSelector:sel];
            return;
        }
    }
    self.view.hidden = YES;
}

// 三个开关互斥：打开任意一个，另外两个自动关掉
- (void)swChanged:(UISwitch *)sw {
    if (self.updatingUI) return;
    self.updatingUI = YES;

    NSInteger k = sw.tag;
    BXSourceKind want = (k == 2) ? BXSourceRTSP : (k == 1 ? BXSourceLocal : BXSourceNone);

    // 用户把当前已开的那个关掉 -> 视为「关闭」
    if (!sw.isOn && want == self.source) {
        want = BXSourceNone;
    }

    switch (want) {
        case BXSourceNone:
            [self stopAll];
            self.source = BXSourceNone;
            [self persistSource];
            break;

        case BXSourceLocal:
            [self stopNetwork];              // 先把 RTSP 断开，避免两路同时抢
            self.source = BXSourceLocal;
            [self persistSource];
            if (self.bridge.sourcePath.length) {
                self.bridge.enabled = YES;
                [[BXFloatStore shared] setObject:@(YES) forKey:@"bx.vcam.enabled"];
            } else {
                [self presentPicker];        // 还没选片，先让用户选
            }
            break;

        case BXSourceRTSP:
            [self stopNetwork];              // 先断开别的源
            self.bridge.sourcePath.length ? (void)0 : (void)0;
            [self startRTSP];                // 异步连流，成功后自己切状态
            break;
    }

    self.updatingUI = NO;
    [self reload];
}

- (void)primaryTapped {
    if (self.connecting) return;
    if (self.bridge.enabled) {
        [self stopAll];
        [self reload];
        return;
    }
    if (self.source == BXSourceLocal) {
        if (self.bridge.sourcePath.length) {
            self.bridge.enabled = YES;
            [[BXFloatStore shared] setObject:@(YES) forKey:@"bx.vcam.enabled"];
            [self reload];
        } else {
            [self presentPicker];
        }
        return;
    }
    [self startRTSP];
}

// 核心修复：连流永不在主线程
- (void)startRTSP {
    if (self.connecting) return;
    NSString *url = [self savedURL];
    if (!url.length) { [self editURLTapped]; return; }

    self.connecting = YES;
    [self reload];

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
            err = [NSError errorWithDomain:@"BXPanel" code:-1
                                  userInfo:@{NSLocalizedDescriptionKey: e.reason ?: @"未知异常"}];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s2 = weakSelf;
            if (!s2) return;
            s2.connecting = NO;

            if (ok) {
                s2.bridge.enabled = YES;
                s2.source = BXSourceRTSP;
                [[BXFloatStore shared] setObject:@(YES) forKey:@"bx.vcam.enabled"];
                [[BXFloatStore shared] setObject:@(YES) forKey:@"bx.rtsp.enabled"];
                [[BXFloatStore shared] setObject:url forKey:@"bx.rtsp.url"];
            } else {
                s2.source = BXSourceNone;
                [[BXFloatStore shared] setObject:@(NO) forKey:@"bx.rtsp.enabled"];
                NSLog(@"[BXFloat][panel] 连流失败: %@", err);
                UIAlertController *ac =
                    [UIAlertController alertControllerWithTitle:@"连接失败"
                                                        message:err.localizedDescription ?: @"无法连接该地址"
                                                 preferredStyle:UIAlertControllerStyleAlert];
                [ac addAction:[UIAlertAction actionWithTitle:@"好"
                                                      style:UIAlertActionStyleCancel
                                                    handler:nil]];
                [[s2 topMost] presentViewController:ac animated:YES completion:nil];
            }
            [s2 persistSource];
            [s2 reload];
        });
    });
}

- (void)stopNetwork {
    [self.bridge stopNetworkSources];
}

- (void)stopAll {
    [self stopNetwork];
    // 顺手关掉预览窗，保证「关闭」= 一切停止
    @try {
        Class pv = NSClassFromString(@"BXPreviewWindow");
        if (pv) {
            id shared = [pv performSelector:NSSelectorFromString(@"shared")];
            SEL hide = NSSelectorFromString(@"hidePreview");
            if (shared && [shared respondsToSelector:hide]) [shared performSelector:hide];
        }
    } @catch (NSException *e) {}

    self.bridge.enabled = NO;
    [[BXFloatStore shared] setObject:@(NO) forKey:@"bx.vcam.enabled"];
    [[BXFloatStore shared] setObject:@(NO) forKey:@"bx.rtsp.enabled"];
}

- (void)editURLTapped {
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"流地址"
                         message:@"rtsp://ip:554/路径  或  http://ip:8080/index.m3u8"
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
    [[self topMost] presentViewController:ac animated:YES completion:nil];
}

- (void)presentPicker {
    _picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.movie"]
                                                                   inMode:UIDocumentPickerModeImport];
    _picker.delegate = self;
    _picker.allowsMultipleSelection = NO;
    [[self topMost] presentViewController:_picker animated:YES completion:nil];
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
        self.source = BXSourceLocal;
        [self persistSource];
    }
    [self reload];
}

- (void)tileTapped:(UITapGestureRecognizer *)g {
    NSInteger tag = g.view.tag;
    BXCaptureBridge *b = self.bridge;
    BXFloatStore *st = [BXFloatStore shared];
    switch (tag) {
        case 0:
            b.mirror = !b.mirror;
            [st setObject:@(b.mirror) forKey:@"bx.vcam.mirror"];
            break;
        case 1: {
            NSInteger r = (b.rotation + 90) % 360;
            b.rotation = r;
            [st setObject:@(r / 90) forKey:@"bx.vcam.rotation"];
            break;
        }
        case 2:
            [[BXPreviewWindow shared] showWithURL:[self savedURL]];
            return;
        case 3:
            [self presentPicker];
            return;
        case 4: {
            NSString *msg = [NSString stringWithFormat:
                @"hook：%@\n接管采集：%lu\n已替换：%lu 帧\n直通：%lu 帧\n来源：%@",
                b.installed ? @"已装" : @"未装",
                (unsigned long)b.capturedOutputs,
                (unsigned long)b.replacedFrames,
                (unsigned long)b.passthroughFrames,
                b.rtspURL.length ? b.rtspURL : (b.sourcePath ?: @"无")];
            UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"运行状态"
                                                                       message:msg
                                                                preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
            [[self topMost] presentViewController:ac animated:YES completion:nil];
            return;
        }
        default:
            break;
    }
    [self reload];
}

#pragma mark - 刷新

- (void)reload {
    if (!_segButtons.count) return;

    BXSourceKind cur = self.source;
    if (self.connecting) cur = BXSourceRTSP;          // 连接中保持 RTSP 开关为开
    else if (self.bridge.rtspURL.length) cur = BXSourceRTSP;
    else if (self.bridge.sourcePath.length && cur == BXSourceRTSP) cur = BXSourceLocal;

    if (!self.updatingUI) {
        self.updatingUI = YES;
        if (self.swNone)  [self.swNone setOn:(cur == BXSourceNone) animated:YES];
        if (self.swLocal) [self.swLocal setOn:(cur == BXSourceLocal) animated:YES];
        if (self.swRTSP)  [self.swRTSP setOn:(cur == BXSourceRTSP) animated:YES];
        self.swNone.enabled = !self.connecting;
        self.swLocal.enabled = !self.connecting;
        self.swRTSP.enabled = !self.connecting;
        self.updatingUI = NO;
    }

    NSString *rtsp = self.bridge.rtspURL;
    NSString *local = self.bridge.sourcePath;
    BOOL connected = (cur == BXSourceRTSP && rtsp.length > 0) ||
                     (cur == BXSourceLocal && local.length > 0);

    if (self.connecting) {
        _statusIcon.text = @"⋯";
        _statusIcon.textColor = C_ACCENT();
        _statusTitle.text = @"连接中…";
        _statusDetail.text = [self savedURL];
    } else if (connected) {
        _statusIcon.text = @"✓";
        _statusIcon.textColor = C_GREEN();
        _statusTitle.text = (cur == BXSourceRTSP) ? @"RTSP 已连接" : @"本地视频";
        _statusDetail.text = (cur == BXSourceRTSP) ? rtsp : local.lastPathComponent;
    } else {
        _statusIcon.text = @"○";
        _statusIcon.textColor = C_SUB();
        _statusTitle.text = @"未连接";
        _statusDetail.text = [self savedURL];
    }

    NSString *pt;
    UIColor *bg;
    UIColor *fg;
    if (self.connecting) {
        pt = @"连接中…"; bg = C_CARD(); fg = C_SUB();
    } else if (self.bridge.enabled) {
        pt = (cur == BXSourceRTSP) ? @"断开连接" : @"停止替换";
        bg = C_CARD(); fg = C_TEXT();
    } else {
        pt = (cur == BXSourceRTSP) ? @"开始拉流" : @"开始替换";
        bg = C_ACCENT(); fg = [UIColor whiteColor];
    }
    [_primary setTitle:pt forState:UIControlStateNormal];
    _primary.backgroundColor = bg;
    [_primary setTitleColor:fg forState:UIControlStateNormal];
    _primary.enabled = !self.connecting;

    for (NSInteger i = 0; i < _tiles.count && i < _tileValues.count; i++) {
        UILabel *v = _tileValues[i];
        switch (i) {
            case 0: v.text = self.bridge.mirror ? @"开" : @"关闭"; break;
            case 1: v.text = [NSString stringWithFormat:@"%ld°", (long)self.bridge.rotation]; break;
            case 2: v.text = self.bridge.sourcePath.length ? self.bridge.sourcePath.lastPathComponent : @"未选择"; break;
            case 3: v.text = [NSString stringWithFormat:@"%lu 帧", (unsigned long)self.bridge.replacedFrames]; break;
            default: break;
        }
    }
}

@end
