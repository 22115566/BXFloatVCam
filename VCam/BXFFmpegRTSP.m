//
//  BXFFmpegRTSP.m
//
//  FFmpeg 直连 RTSP → 硬件无关的 BGRA CVPixelBuffer。
//  解码串: av_read_frame → avcodec_send_packet → avcodec_receive_frame
//          → sws_scale(YUV420P→BGRA) → CVPixelBuffer
//
//  线程模型:
//    后台串行队列持续解码，只保留「最新一帧」，采集桥取帧时直接拿，
//    既不阻塞摄像头回调，也不会因为积压导致延迟越来越大。
//

#import "BXFFmpegRTSP.h"
#import <CoreImage/CoreImage.h>

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libswscale/swscale.h>

@interface BXFFmpegRTSP () {
    AVFormatContext *_fmt;
    AVCodecContext  *_dec;
    struct SwsContext *_sws;
    int             _streamIndex;
    int             _srcW, _srcH;
    enum AVPixelFormat _srcFmt;

    CVPixelBufferRef _latest;          // 受 lock 保护
    NSLock          *_lock;
    dispatch_queue_t _decodeQueue;
    BOOL            _stopRequested;
    CIContext       *_ci;
    CVPixelBufferPoolRef _pool;
    CGSize          _poolSize;
}
@property (atomic, assign) BOOL running;
@property (atomic, copy)   NSString *urlString;
@property (atomic, assign) CGSize size;
@property (atomic, assign) NSUInteger decodedFrames;
@property (atomic, assign) NSUInteger droppedFrames;
@end

@implementation BXFFmpegRTSP

- (instancetype)init {
    if ((self = [super init])) {
        _lock = [NSLock new];
        _decodeQueue = dispatch_queue_create("bx.ffmpeg.rtsp", DISPATCH_QUEUE_SERIAL);
        _ci = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
        _streamIndex = -1;
    }
    return self;
}

- (void)dealloc { [self stop]; }

#pragma mark - 启动

- (BOOL)startWithURLString:(NSString *)urlString error:(NSError **)error {
    [self stop];
    if (!urlString.length) {
        if (error) *error = [NSError errorWithDomain:@"BXRTSP" code:1
                                            userInfo:@{NSLocalizedDescriptionKey: @"地址为空"}];
        return NO;
    }

    avformat_network_init();

    AVDictionary *opts = NULL;
    // 低延迟关键项
    av_dict_set(&opts, "rtsp_transport", "tcp", 0);
    av_dict_set(&opts, "stimeout", "5000000", 0);      // 5s 超时（微秒）
    av_dict_set(&opts, "max_delay", "0", 0);
    av_dict_set(&opts, "reorder_queue_size", "0", 0);
    av_dict_set(&opts, "fflags", "nobuffer", 0);
    av_dict_set(&opts, "flags", "low_delay", 0);
    av_dict_set(&opts, "buffer_size", "1048576", 0);

    int ret = avformat_open_input(&_fmt, urlString.UTF8String, NULL, &opts);
    av_dict_free(&opts);
    if (ret < 0 || !_fmt) {
        if (error) *error = [NSError errorWithDomain:@"BXRTSP" code:ret
                                            userInfo:@{NSLocalizedDescriptionKey:
                                                           [NSString stringWithFormat:@"打开流失败(%d)", ret]}];
        return NO;
    }

    ret = avformat_find_stream_info(_fmt, NULL);
    if (ret < 0) {
        if (error) *error = [NSError errorWithDomain:@"BXRTSP" code:ret
                                            userInfo:@{NSLocalizedDescriptionKey: @"读取流信息失败"}];
        [self stop];
        return NO;
    }

    _streamIndex = av_find_best_stream(_fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (_streamIndex < 0) {
        if (error) *error = [NSError errorWithDomain:@"BXRTSP" code:_streamIndex
                                            userInfo:@{NSLocalizedDescriptionKey: @"没有视频流"}];
        [self stop];
        return NO;
    }

    AVStream *st = _fmt->streams[_streamIndex];
    const AVCodec *codec = avcodec_find_decoder(st->codecpar->codec_id);
    if (!codec) {
        if (error) *error = [NSError errorWithDomain:@"BXRTSP" code:-1
                                            userInfo:@{NSLocalizedDescriptionKey: @"没有可用解码器"}];
        [self stop];
        return NO;
    }

    _dec = avcodec_alloc_context3(codec);
    avcodec_parameters_to_context(_dec, st->codecpar);
    _dec->thread_count = 2;
    _dec->flags |= AV_CODEC_FLAG_LOW_DELAY;

    if (avcodec_open2(_dec, codec, NULL) < 0) {
        if (error) *error = [NSError errorWithDomain:@"BXRTSP" code:-2
                                            userInfo:@{NSLocalizedDescriptionKey: @"解码器初始化失败"}];
        [self stop];
        return NO;
    }

    _srcW = _dec->width;
    _srcH = _dec->height;
    _srcFmt = _dec->pix_fmt;
    if (_srcW <= 0 || _srcH <= 0) {
        if (error) *error = [NSError errorWithDomain:@"BXRTSP" code:-3
                                            userInfo:@{NSLocalizedDescriptionKey: @"分辨率无效"}];
        [self stop];
        return NO;
    }

    _sws = sws_getContext(_srcW, _srcH, _srcFmt,
                          _srcW, _srcH, AV_PIX_FMT_BGRA,
                          SWS_BILINEAR, NULL, NULL, NULL);
    if (!_sws) {
        if (error) *error = [NSError errorWithDomain:@"BXRTSP" code:-4
                                            userInfo:@{NSLocalizedDescriptionKey: @"sws 初始化失败"}];
        [self stop];
        return NO;
    }

    self.size = CGSizeMake(_srcW, _srcH);
    self.urlString = urlString;
    self.running = YES;
    _stopRequested = NO;

    NSLog(@"[BXRTSP] 已连接 %@  %dx%d  codec=%s", urlString, _srcW, _srcH, codec->name);

    __weak typeof(self) weakSelf = self;
    dispatch_async(_decodeQueue, ^{ [weakSelf decodeLoop]; });
    return YES;
}

#pragma mark - 解码循环

- (void)decodeLoop {
    AVPacket *pkt = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    uint8_t *bgra = NULL;
    int bgraStride = _srcW * 4;
    bgra = (uint8_t *)malloc((size_t)bgraStride * (size_t)_srcH);

    while (!_stopRequested && _fmt && pkt && frame && bgra) {
        int ret = av_read_frame(_fmt, pkt);
        if (ret < 0) {
            if (ret == AVERROR(EAGAIN)) { usleep(2000); continue; }
            NSLog(@"[BXRTSP] 读帧结束/出错 %d，2 秒后重连", ret);
            break;
        }
        if (pkt->stream_index != _streamIndex) { av_packet_unref(pkt); continue; }

        if (avcodec_send_packet(_dec, pkt) == 0) {
            while (avcodec_receive_frame(_dec, frame) == 0) {
                [self publishFrame:frame bgra:bgra stride:bgraStride];
                av_frame_unref(frame);
            }
        }
        av_packet_unref(pkt);
    }

    free(bgra);
    if (frame) av_frame_free(&frame);
    if (pkt) av_packet_free(&pkt);
}

- (void)publishFrame:(AVFrame *)frame bgra:(uint8_t *)bgra stride:(int)stride {
    uint8_t *dst[4] = { bgra, NULL, NULL, NULL };
    int dstStride[4] = { stride, 0, 0, 0 };
    sws_scale(_sws, (const uint8_t *const *)frame->data, frame->linesize,
              0, frame->height, dst, dstStride);

    CVPixelBufferRef px = NULL;
    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(frame->width),
        (id)kCVPixelBufferHeightKey: @(frame->height),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    if (CVPixelBufferCreate(kCFAllocatorDefault, (size_t)frame->width, (size_t)frame->height,
                            kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attrs, &px) != kCVReturnSuccess || !px) {
        return;
    }
    CVPixelBufferLockBaseAddress(px, 0);
    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(px);
    size_t dstBpr = CVPixelBufferGetBytesPerRow(px);
    size_t copyBytes = (size_t)MIN((int)dstBpr, stride);
    for (int y = 0; y < frame->height; y++) {
        memcpy(base + y * dstBpr, bgra + (size_t)y * stride, copyBytes);
    }
    CVPixelBufferUnlockBaseAddress(px, 0);

    [_lock lock];
    if (_latest) CVPixelBufferRelease(_latest);
    _latest = px;                       // 转移持有
    self.decodedFrames = self.decodedFrames + 1;
    [_lock unlock];
}

#pragma mark - 取帧

- (CVPixelBufferRef)copyNextFrameScaledTo:(CGSize)targetSize CF_RETURNS_RETAINED {
    CVPixelBufferRef src = NULL;
    [_lock lock];
    if (_latest) { src = CVPixelBufferRetain(_latest); }
    [_lock unlock];
    if (!src) return NULL;

    BOOL needRotate = (_rotation % 360) != 0;
    BOOL needMirror = _mirror;
    BOOL needScale = !CGSizeEqualToSize(targetSize, CGSizeZero) &&
                     (fabs(targetSize.width - (CGFloat)CVPixelBufferGetWidth(src)) > 1.0 ||
                      fabs(targetSize.height - (CGFloat)CVPixelBufferGetHeight(src)) > 1.0);

    if (!needRotate && !needMirror && !needScale) return src;

    CIImage *img = [CIImage imageWithCVPixelBuffer:src];
    CGFloat w = (CGFloat)CVPixelBufferGetWidth(src);
    CGFloat h = (CGFloat)CVPixelBufferGetHeight(src);

    if (needScale) {
        img = [img imageByApplyingTransform:CGAffineTransformMakeScale(targetSize.width / w,
                                                                      targetSize.height / h)];
    }
    if (needMirror) {
        CGFloat width = needScale ? targetSize.width : w;
        img = [img imageByApplyingTransform:CGAffineTransformMakeScale(-1, 1)];
        img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(width, 0)];
    }
    if (needRotate) {
        img = [img imageByApplyingTransform:CGAffineTransformMakeRotation((CGFloat)(_rotation * M_PI / 180.0))];
        img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(
            img.extent.origin.x < 0 ? -img.extent.origin.x : 0,
            img.extent.origin.y < 0 ? -img.extent.origin.y : 0)];
    }

    CGSize outSize = needScale ? targetSize : CGSizeMake(w, h);
    if (_rotation == 90 || _rotation == 270) outSize = CGSizeMake(outSize.height, outSize.width);

    if (!_pool || !CGSizeEqualToSize(_poolSize, outSize)) {
        if (_pool) { CVPixelBufferPoolRelease(_pool); _pool = NULL; }
        NSDictionary *poolAttrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @(outSize.width),
            (id)kCVPixelBufferHeightKey: @(outSize.height),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        };
        CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)poolAttrs, &_pool);
        _poolSize = outSize;
    }

    CVPixelBufferRef dst = NULL;
    if (_pool && CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _pool, &dst) == kCVReturnSuccess && dst) {
        [_ci render:img toCVPixelBuffer:dst
               bounds:CGRectMake(0, 0, outSize.width, outSize.height)
           colorSpace:CGColorSpaceCreateDeviceRGB()];
    }
    CVPixelBufferRelease(src);
    return dst;
}

#pragma mark - 停止

- (void)stop {
    _stopRequested = YES;
    self.running = NO;

    if (_sws) { sws_freeContext(_sws); _sws = NULL; }
    if (_dec) { avcodec_free_context(&_dec); _dec = NULL; }
    if (_fmt) { avformat_close_input(&_fmt); _fmt = NULL; }

    [_lock lock];
    if (_latest) { CVPixelBufferRelease(_latest); _latest = NULL; }
    [_lock unlock];

    if (_pool) { CVPixelBufferPoolRelease(_pool); _pool = NULL; }
    self.urlString = nil;
}

@end
