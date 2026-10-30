//
//  BXFFmpegRTSP.h —— RTSP 直连（FFmpeg），输出 CVPixelBuffer
//
//  与 BXVideoSource / BXStreamVideoSource 接口对齐，采集桥可直接替换。
//  低延迟配置：TCP 传输 + nobuffer + 队列长度为 0，实测 200~600ms。
//

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CoreGraphics.h>

@interface BXFFmpegRTSP : NSObject

/// 打开 rtsp:// 地址并在后台线程持续解码
- (BOOL)startWithURLString:(NSString *)urlString error:(NSError **)error;

- (void)stop;

@property (nonatomic, readonly, getter=isRunning) BOOL running;
@property (nonatomic, readonly) NSString *urlString;
@property (nonatomic, readonly) CGSize size;

/// 统计
@property (nonatomic, readonly) NSUInteger decodedFrames;
@property (nonatomic, readonly) NSUInteger droppedFrames;

/// 画面选项
@property (atomic, assign) BOOL mirror;
@property (atomic, assign) NSInteger rotation;

/// 取最新一帧（已应用镜像/旋转/缩放）。调用方 CFRelease。
- (CVPixelBufferRef)copyNextFrameScaledTo:(CGSize)targetSize CF_RETURNS_RETAINED;

@end
