//
//  BXCaptureBridge.h —— 虚拟摄像头核心
//
//  原理:
//    App 创建 AVCaptureVideoDataOutput 后会调 setSampleBufferDelegate:queue:
//    我们把这个方法换掉: 保存 App 原来的 delegate, 改成注册自己。
//    等 App 的代理回调被调用时, 我们把摄像头帧换成视频帧, 再转发给 App 的 delegate。
//
//  安全性:
//    - 未开启虚拟摄像头时 100% 直通, 不影响任何行为
//    - 视频未加载时 100% 直通
//    - getter 也换成返回 App 原来的 delegate, 防止 App 自查
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

@interface BXCaptureBridge : NSObject

+ (instancetype)shared;

/// 是否启用虚拟摄像头（未启用时完全直通）
@property (atomic, assign) BOOL enabled;

/// 画面选项（转发到底层视频源）
@property (atomic, assign) BOOL loop;
@property (atomic, assign) BOOL mirror;
@property (atomic, assign) NSInteger rotation;

/// 当前视频源
@property (nonatomic, readonly) NSString *sourcePath;

/// 换成 RTSP 直连（内置 FFmpeg）。优先级最高。
- (BOOL)useRTSPURLString:(NSString *)urlString error:(NSError **)error;

@property (nonatomic, readonly) NSString *rtspURL;

/// 进入造帧的次数（排查用）
@property (nonatomic, readonly) NSUInteger attemptFrames;

/// 解码统计（排查用）
@property (nonatomic, readonly) NSUInteger decodedFrames;
@property (nonatomic, readonly) NSString *streamFrameReason;
@property (nonatomic, readonly) NSString *gateReason;

/// 取当前 RTSP/HLS 帧（给预览窗复用，避免开第二路连接）
- (CVPixelBufferRef)copyLatestStreamFrame CF_RETURNS_RETAINED;

/// 停止 RTSP / 网络流（本地视频不受影响）
- (void)stopNetworkSources;

/// 换成网络流（HLS / HTTP MP4）。走这条路时本地视频源不生效。
- (BOOL)useStreamURLString:(NSString *)urlString error:(NSError **)error;

@property (nonatomic, readonly) NSString *streamURL;

/// 换成另一个视频文件
- (BOOL)useVideoAtPath:(NSString *)path error:(NSError **)error;

/// 装载 hook。constructor 里调一次即可。
- (void)install;

/// 状态
@property (nonatomic, readonly) BOOL installed;
@property (nonatomic, readonly) NSUInteger replacedFrames;
@property (nonatomic, readonly) NSUInteger passthroughFrames;

/// 有多少个采集输出被我们接管了 delegate（0 = App 还没开摄像头）
@property (nonatomic, readonly) NSUInteger capturedOutputs;

@end
