//
//  BXModules.m —— 虚拟摄像头控制面板
//

#import "BXFloatModule.h"
#import "BXFloatStore.h"
#import "BXFloatWindow.h"
#import "BXFloatMenuController.h"
#import "BXCaptureBridge.h"
#import "BXVideoSource.h"
#import "BXConfig.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - 选片器

@interface BXPickerProxy : NSObject <UIDocumentPickerDelegate>
@property (nonatomic, copy) void (^onPick)(NSURL *url);
@end

@implementation BXPickerProxy

- (void)documentPicker:(UIDocumentPickerViewController *)c
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *u = urls.firstObject;
    if (u && self.onPick) self.onPick(u);
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)c {
    NSLog(@"[BXFloat][vcam] 选择取消");
}

@end

static BXPickerProxy *gPicker = nil;   // 持有，避免被释放

static UIViewController *BXTopViewController(void) {
    UIViewController *top = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow) { top = w.rootViewController; break; }
    }
    if (!top) {
        top = [UIApplication sharedApplication].windows.firstObject.rootViewController;
    }
    while (top.presentedViewController) top = top.presentedViewController;
    return top;
}

static void BXPresentVideoPicker(void) {
    UIDocumentPickerViewController *p =
        [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.movie"]
                                                             inMode:UIDocumentPickerModeImport];
    p.delegate = gPicker;
    p.allowsMultipleSelection = NO;
    [BXTopViewController() presentViewController:p animated:YES completion:nil];
}

#pragma mark - 注册

void BXRegisterBuiltinModules(void) {
    BXFloatRegistry *reg = [BXFloatRegistry shared];
    BXCaptureBridge *bridge = [BXCaptureBridge shared];

    // 选片回调：载入视频 + 刷新面板
    if (!gPicker) {
        gPicker = [BXPickerProxy new];
        gPicker.onPick = ^(NSURL *url) {
            NSError *e = nil;
            BOOL ok = [[BXCaptureBridge shared] useVideoAtPath:url.path error:&e];
            NSLog(@"[BXFloat][vcam] 选片 %@ -> %@", url.lastPathComponent, ok ? @"成功" : e);
            [[BXFloatStore shared] setObject:url.path forKey:@"bx.vcam.path"];
            [[BXFloatWindow shared].menu reload];
        };
    }

    // ---- 主开关 ----
    BXFloatModule *enable = [BXFloatModule toggleWithKey:@"bx.vcam.enabled"
                                                   title:@"虚拟摄像头"
                                                  action:^(BXFloatModule *m, id v) {
        bridge.enabled = m.on;
        [[BXFloatStore shared] setObject:@(m.on) forKey:m.key];
        NSLog(@"[BXFloat][vcam] 虚拟摄像头 %@", m.on ? @"开" : @"关");
        [[BXFloatWindow shared].menu reload];
    }];
    enable.subtitle = @"用视频替换摄像头画面";

    // ---- 选择视频 ----
    BXFloatModule *pick = [BXFloatModule buttonWithKey:@"bx.vcam.pick"
                                                 title:@"选择视频"
                                                action:^(BXFloatModule *m, id v) {
        BXPresentVideoPicker();
    }];
    NSString *cur = [[BXFloatStore shared] objectForKey:@"bx.vcam.path"];
    pick.subtitle = cur.length ? cur.lastPathComponent : @"未选择";

    // ---- 循环 ----
    BXFloatModule *loop = [BXFloatModule toggleWithKey:@"bx.vcam.loop"
                                                 title:@"循环播放"
                                                action:^(BXFloatModule *m, id v) {
        [BXCaptureBridge shared].loop = m.on;
        [[BXFloatStore shared] setObject:@(m.on) forKey:m.key];
    }];
    loop.on = YES;
    loop.subtitle = @"播完从头再来";

    // ---- 镜像 ----
    BXFloatModule *mirror = [BXFloatModule toggleWithKey:@"bx.vcam.mirror"
                                                   title:@"水平镜像"
                                                  action:^(BXFloatModule *m, id v) {
        [BXCaptureBridge shared].mirror = m.on;
        [[BXFloatStore shared] setObject:@(m.on) forKey:m.key];
    }];
    mirror.subtitle = @"自拍习惯的镜像效果";

    // ---- 旋转 ----
    BXFloatModule *rot = [BXFloatModule pickerWithKey:@"bx.vcam.rotation"
                                                title:@"旋转"
                                              options:@[@"0°", @"90°", @"180°", @"270°"]
                                               action:^(BXFloatModule *m, id v) {
        NSInteger deg = m.selectedIndex * 90;
        [BXCaptureBridge shared].rotation = deg;
        [[BXFloatStore shared] setObject:@(m.selectedIndex) forKey:m.key];
    }];
    rot.subtitle = @"画面方向不对时调这里";

    // ---- 状态 ----
    BXFloatModule *stat = [BXFloatModule buttonWithKey:@"bx.vcam.status"
                                                 title:@"运行状态"
                                                action:^(BXFloatModule *m, id v) {
        BXCaptureBridge *b = [BXCaptureBridge shared];
        NSString *hint = @"";
        if (b.capturedOutputs == 0) {
            hint = @"\n\n⚠️ App 还没创建摄像头采集。\n先去开直播或点「+」进拍摄页，再回来看。";
        } else if (b.replacedFrames == 0) {
            hint = @"\n\n⚠️ 已接管 delegate 但没替换成功。\n检查开关是否打开、视频是否已选。";
        }
        NSString *msg = [NSString stringWithFormat:
            @"hook: %@\n接管采集: %lu 个\n启用: %@\n视频: %@\n已替换: %lu 帧\n直通: %lu 帧%@",
            b.installed ? @"已装" : @"未装",
            (unsigned long)b.capturedOutputs,
            b.enabled ? @"是" : @"否",
            b.sourcePath.length ? b.sourcePath.lastPathComponent : @"(无)",
            (unsigned long)b.replacedFrames,
            (unsigned long)b.passthroughFrames,
            hint];
        UIAlertController *ac =
            [UIAlertController alertControllerWithTitle:@"虚拟摄像头状态"
                                               message:msg
                                        preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"好"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
        [BXTopViewController() presentViewController:ac animated:YES completion:nil];
    }];
    stat.subtitle = @"看帧有没有被替换";

    // ---- RTSP 拉流 ----
    BXFloatModule *rtsp = [BXFloatModule toggleWithKey:@"bx.rtsp.enabled"
                                                 title:@"RTSP 拉流"
                                                action:^(BXFloatModule *m, id v) {
        BXCaptureBridge *b = [BXCaptureBridge shared];
        if (!m.on) {
            [b stopNetworkSources];
            [[BXFloatStore shared] setObject:@(NO) forKey:m.key];
            return;
        }
        NSString *url = [[BXFloatStore shared] objectForKey:@"bx.rtsp.url"];
        if (!url.length) url = kBXDefaultStreamURL;
        if (!url.length) {
            m.on = NO;
            UIAlertController *ac =
                [UIAlertController alertControllerWithTitle:@"没有流地址"
                                                   message:@"先点「RTSP 地址」填一个"
                                            preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
            [BXTopViewController() presentViewController:ac animated:YES completion:nil];
            return;
        }
        NSError *e = nil;
        BOOL isRTSP = [url hasPrefix:@"rtsp://"];
        BOOL ok = isRTSP ? [b useRTSPURLString:url error:&e]
                         : [b useStreamURLString:url error:&e];
        if (!ok) {
            m.on = NO;
            NSLog(@"[BXFloat][vcam] 拉流失败 %@", e);
            [[BXFloatWindow shared].menu reload];
            return;
        }
        b.enabled = YES;
        [[BXFloatStore shared] setObject:@(YES) forKey:m.key];
        [[BXFloatStore shared] setObject:url forKey:@"bx.rtsp.url"];
        [[BXFloatWindow shared].menu reload];
    }];
    rtsp.subtitle = @"rtsp:// 直连 / http 走 HLS";

    // ---- RTSP 地址 ----
    BXFloatModule *rtspURL = [BXFloatModule buttonWithKey:@"bx.rtsp.edit"
                                                    title:@"RTSP 地址"
                                                   action:^(BXFloatModule *m, id v) {
        NSString *cur = [[BXFloatStore shared] objectForKey:@"bx.rtsp.url"];
        if (!cur.length) cur = kBXDefaultStreamURL;
        UIAlertController *ac =
            [UIAlertController alertControllerWithTitle:@"流地址"
                                               message:@"rtsp://ip:554/xxx 或 http://ip:8080/index.m3u8"
                                        preferredStyle:UIAlertControllerStyleAlert];
        [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.text = cur;
            tf.placeholder = @"rtsp://192.168.1.4:8554/live/123";
            tf.keyboardType = UIKeyboardTypeURL;
            tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
            tf.autocorrectionType = UITextAutocorrectionTypeNo;
        }];
        [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [ac addAction:[UIAlertAction actionWithTitle:@"保存并连接" style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *a) {
            NSString *url = ac.textFields.firstObject.text ?: @"";
            url = [url stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (!url.length) return;
            [[BXFloatStore shared] setObject:url forKey:@"bx.rtsp.url"];
            BXCaptureBridge *b = [BXCaptureBridge shared];
            NSError *e = nil;
            BOOL ok = [url hasPrefix:@"rtsp://"] ? [b useRTSPURLString:url error:&e]
                                                 : [b useStreamURLString:url error:&e];
            NSLog(@"[BXFloat][vcam] 保存地址 %@ -> %@", url, ok ? @"成功" : e);
            if (ok) b.enabled = YES;
            BXFloatModule *t = [[BXFloatRegistry shared] moduleForKey:@"bx.rtsp.enabled"];
            if (t) { t.on = ok; [[BXFloatStore shared] setObject:@(ok) forKey:t.key]; }
            [[BXFloatWindow shared].menu reload];
        }]];
        [BXTopViewController() presentViewController:ac animated:YES completion:nil];
    }];
    NSString *savedURL = [[BXFloatStore shared] objectForKey:@"bx.rtsp.url"];
    rtspURL.subtitle = savedURL.length ? savedURL : (kBXDefaultStreamURL.length ? kBXDefaultStreamURL : @"未设置");

    [reg registerModules:@[enable, rtsp, rtspURL, pick, loop, mirror, rot, stat]];

    NSLog(@"[BXFloat][vcam] 已注册 %lu 个模块", (unsigned long)[reg modules].count);
}
