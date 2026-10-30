//
//  BXConfig.h —— vcam 版配置
//

#import <Foundation/Foundation.h>

/// 目标 App 白名单。调试时可以设 kBXAttachEverywhere = YES。
static NSString *const kBXTargetBundleIDs[] = {
    @"com.ss.iphone.ugc.Aweme",    // 抖音
    @"com.jiangjia.gif",           // 快手
    @"com.tencent.xin",            // 微信
    @"com.xingin.discover",        // 小红书
};
static const int kBXTargetBundleIDCount = 4;

/// 是否在所有 App 里都出现（调试用，正式设 NO）
static const BOOL kBXAttachEverywhere = YES;

/// 网络流地址（HLS: http://ip:端口/live.m3u8）。填了就在启动时自动开播。
/// RTSP 不被 AVFoundation 支持，必须先转成 HLS。
static NSString *const kBXDefaultStreamURL = @"rtsp://192.168.1.4:8554/live/123";

/// 启动时自动连流。默认 NO —— 在启动阶段连网络会把主线程卡住，
/// 导致系统判定启动超时直接杀进程。请从面板「RTSP 拉流」开关启动。
static const BOOL kBXAutoStartStream = NO;

static NSString *const kBXMenuTitle = @"百相 Lite";
static NSString *const kBXVersion   = @"1.0.0";
