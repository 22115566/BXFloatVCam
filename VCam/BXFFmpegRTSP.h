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
@property (nonatomic, readonly) NSString *lastReason;   // 上次取帧失败的原因
@property (nonatomic, readonly) NSUInteger decodedFrames;
@property (nonatomic, readonly) NSUInteger droppedFrames;

/// 目标像素格式：设成摄像头的格式后，缩放会直接渲染成该格式，不再二次转换
@property (nonatomic, assign) OSType targetFormat;

/// 画面选项
@property (atomic, assign) BOOL mirror;
@property (atomic, assign) NSInteger rotation;

/// 有没有音频轨
- (BOOL)hasAudio;

/// 按摄像头的实际参数配置重采样目标（百相的做法：先读 ASBD 再对齐）
- (void)configureAudioSampleRate:(double)rate channels:(int)channels;
/// 当前重采样输出的声道数
- (int)audioChannels;

/// 取最新音频（S16 交错，48kHz，双声道）。返回写入的帧数，0 表示暂时没有。
- (NSUInteger)copyAudioS16:(int16_t *)dst maxFrames:(NSUInteger)maxFrames;

/// 取最新一帧（已应用镜像/旋转/缩放）。调用方 CFRelease。
- (CVPixelBufferRef)copyNextFrameScaledTo:(CGSize)targetSize CF_RETURNS_RETAINED;

/// 按摄像头 PTS 取帧并缩放到指定尺寸（用于对齐摄像头时间戳）
- (CVPixelBufferRef)copyFrameForCameraPTS:(CMTime)cameraPTS scaledTo:(CGSize)targetSize CF_RETURNS_RETAINED;

@end
