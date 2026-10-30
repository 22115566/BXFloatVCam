//
//  BXStreamVideoSource.h —— 网络流 → 逐帧 CVPixelBuffer
//
//  支持: HLS (m3u8) / HTTP 渐进 MP4。AVPlayer 原生支持这两种，
//        RTSP 需要源头转一道（见 README）。
//
//  接口与 BXVideoSource 对齐，直接替换采集桥里的取帧调用即可。
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CoreGraphics.h>

@interface BXStreamVideoSource : NSObject

/// 开始播放网络流。返回 NO 表示 URL 不合法或创建失败。
- (BOOL)startWithURLString:(NSString *)urlString error:(NSError **)error;

/// 停止并释放
- (void)stop;

@property (nonatomic, readonly, getter=isRunning) BOOL running;
@property (nonatomic, readonly) NSString *urlString;
@property (nonatomic, readonly) CGSize size;

/// 画面选项（与本地视频源保持一致）
@property (atomic, assign) BOOL mirror;
@property (atomic, assign) NSInteger rotation;

/// 取当前最新一帧（已应用镜像/旋转/缩放）。调用方负责 CFRelease。
/// targetSize 传 CGSizeZero 表示用流原始分辨率。
- (CVPixelBufferRef)copyNextFrameScaledTo:(CGSize)targetSize CF_RETURNS_RETAINED;

@end
