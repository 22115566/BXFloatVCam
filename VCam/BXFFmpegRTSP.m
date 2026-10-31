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
#include <unistd.h>

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
    uint8_t         *_bgra;        // 转换缓冲（按需重分配，绝不沿用启动时的尺寸）
    size_t          _bgraSize;
    BOOL            _loopActive;   // 解码线程是否在跑（决定由谁负责释放 ffmpeg 上下文）
    NSString       *_lastReason;   // 上次取帧失败原因（排查用）
}
@property (atomic, assign) BOOL running;
@property (atomic, copy)   NSString *urlString;
@property (atomic, assign) CGSize size;
@property (atomic, assign) NSUInteger decodedFrames;
@property (atomic, assign) NSUInteger droppedFrames;

- (BOOL)reopenForReconnect:(NSString *)urlString;
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

// 同步打开（只在后台队列调用）
static int bx_open_sync(AVFormatContext **outFmt, const char *url) {
    AVDictionary *opts = NULL;
    av_dict_set(&opts, "rtsp_transport", "tcp", 0);
    av_dict_set(&opts, "stimeout", "5000000", 0);
    av_dict_set(&opts, "fflags", "nobuffer", 0);
    int ret = avformat_open_input(outFmt, url, NULL, &opts);
    av_dict_free(&opts);
    return ret;
}

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

    // 注意：RTSP 的分辨率有时要等第一帧解码后才知道，
    // 这里不强制要求宽高，sws 在第一帧时惰性创建。
    _srcW = _dec->width;
    _srcH = _dec->height;
    _srcFmt = _dec->pix_fmt;
    if (_srcW > 0 && _srcH > 0) {
        _sws = sws_getContext(_srcW, _srcH, _srcFmt,
                              _srcW, _srcH, AV_PIX_FMT_BGRA,
                              SWS_BILINEAR, NULL, NULL, NULL);
        self.size = CGSizeMake(_srcW, _srcH);
    }
    self.urlString = urlString;
    self.running = YES;
    _stopRequested = NO;

    NSLog(@"[BXRTSP] 已连接 %@  %dx%d  codec=%s", urlString, _srcW, _srcH, codec->name);

    __weak typeof(self) weakSelf = self;
    _loopActive = YES;
    dispatch_async(_decodeQueue, ^{ [weakSelf decodeLoop]; });
    return YES;
}

// 断线重连用：只重新打开流和解码器，不重启整个队列
- (BOOL)reopenForReconnect:(NSString *)urlString {
    AVDictionary *opts = NULL;
    av_dict_set(&opts, "rtsp_transport", "tcp", 0);
    av_dict_set(&opts, "stimeout", "5000000", 0);
    av_dict_set(&opts, "max_delay", "0", 0);
    av_dict_set(&opts, "reorder_queue_size", "0", 0);
    av_dict_set(&opts, "fflags", "nobuffer", 0);
    av_dict_set(&opts, "flags", "low_delay", 0);
    av_dict_set(&opts, "buffer_size", "1048576", 0);

    int ret = avformat_open_input(&_fmt, urlString.UTF8String, NULL, &opts);
    av_dict_free(&opts);
    if (ret < 0 || !_fmt) {
        _lastReason = [NSString stringWithFormat:@"重连打开失败(%d)", ret];
        return NO;
    }

    ret = avformat_find_stream_info(_fmt, NULL);
    if (ret < 0) {
        avformat_close_input(&_fmt); _fmt = NULL;
        _lastReason = @"重连读取流信息失败";
        return NO;
    }

    _streamIndex = av_find_best_stream(_fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (_streamIndex < 0) {
        avformat_close_input(&_fmt); _fmt = NULL;
        _lastReason = @"重连没有视频流";
        return NO;
    }

    AVStream *st = _fmt->streams[_streamIndex];
    const AVCodec *codec = avcodec_find_decoder(st->codecpar->codec_id);
    if (!codec) {
        avformat_close_input(&_fmt); _fmt = NULL;
        _lastReason = @"重连没有可用解码器";
        return NO;
    }

    _dec = avcodec_alloc_context3(codec);
    avcodec_parameters_to_context(_dec, st->codecpar);
    _dec->thread_count = 2;
    _dec->flags |= AV_CODEC_FLAG_LOW_DELAY;

    if (avcodec_open2(_dec, codec, NULL) < 0) {
        avcodec_free_context(&_dec); _dec = NULL;
        avformat_close_input(&_fmt); _fmt = NULL;
        _lastReason = @"重连解码器初始化失败";
        return NO;
    }

    _srcW = _dec->width;
    _srcH = _dec->height;
    _srcFmt = _dec->pix_fmt;
    if (_srcW > 0 && _srcH > 0) {
        if (_sws) { sws_freeContext(_sws); _sws = NULL; }
        _sws = sws_getContext(_srcW, _srcH, _srcFmt,
                              _srcW, _srcH, AV_PIX_FMT_BGRA,
                              SWS_BILINEAR, NULL, NULL, NULL);
        self.size = CGSizeMake(_srcW, _srcH);
    }
    return YES;
}

#pragma mark - 解码循环

- (void)decodeLoop {
    AVPacket *pkt = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    NSString *url = self.urlString;
    int reconnect = 0;

read_again:
    while (!_stopRequested && _fmt && pkt && frame) {
        int ret = av_read_frame(_fmt, pkt);
        if (ret < 0) {
            if (ret == AVERROR(EAGAIN)) { usleep(2000); continue; }
            NSLog(@"[BXRTSP] 读帧结束/出错 %d，准备重连（第 %d 次）", ret, reconnect);
            // 断线自动重连：服务端踢掉旧连接、网络抖动都很常见，
            // 不重连的话画面会永远停在最后一帧（或一直直通真实摄像头）。
            if (_stopRequested || !url.length || reconnect >= 30) break;
            reconnect++;
            usleep(800 * 1000);
            if (_dec) { avcodec_free_context(&_dec); _dec = NULL; }
            if (_fmt) { avformat_close_input(&_fmt); _fmt = NULL; }
            if (![self reopenForReconnect:url]) break;
            continue;
        }
        reconnect = 0;
        if (pkt->stream_index != _streamIndex) { av_packet_unref(pkt); continue; }

        if (avcodec_send_packet(_dec, pkt) == 0) {
            while (avcodec_receive_frame(_dec, frame) == 0) {
                [self publishFrame:frame];
                av_frame_unref(frame);
            }
        }
        av_packet_unref(pkt);
    }

    if (frame) av_frame_free(&frame);
    if (pkt) av_packet_free(&pkt);

    // 上下文只在这里释放：保证不会有人在 av_read_frame 里用着它
    if (_dec) { avcodec_free_context(&_dec); _dec = NULL; }
    if (_fmt) { avformat_close_input(&_fmt); _fmt = NULL; }
    _loopActive = NO;
}

// 关键修复：转换缓冲按「当前帧真实尺寸」分配；sws 与缓冲统一在 _lock 内操作，
// 避免解码线程和采集线程同时读写导致踩内存（表现为进拍摄页瞬间崩溃）。
- (void)publishFrame:(AVFrame *)frame {
    if (!frame || frame->width <= 0 || frame->height <= 0) return;

    [_lock lock];

    if (!_sws || frame->width != _srcW || frame->height != _srcH || (int)frame->format != (int)_srcFmt) {
        if (_sws) { sws_freeContext(_sws); _sws = NULL; }
        _srcW = frame->width;
        _srcH = frame->height;
        _srcFmt = (enum AVPixelFormat)frame->format;
        _sws = sws_getContext(_srcW, _srcH, _srcFmt,
                              _srcW, _srcH, AV_PIX_FMT_BGRA,
                              SWS_BILINEAR, NULL, NULL, NULL);
        self.size = CGSizeMake(_srcW, _srcH);
    }
    if (!_sws) { [_lock unlock]; return; }

    size_t need = (size_t)_srcW * 4u * (size_t)_srcH;
    if (need == 0) { [_lock unlock]; return; }
    if (!_bgra || _bgraSize < need) {
        uint8_t *nb = (uint8_t *)realloc(_bgra, need);
        if (!nb) { [_lock unlock]; return; }
        _bgra = nb;
        _bgraSize = need;
    }

    uint8_t *dst[4] = { _bgra, NULL, NULL, NULL };
    int dstStride[4] = { _srcW * 4, 0, 0, 0 };
    sws_scale(_sws, (const uint8_t *const *)frame->data, frame->linesize,
              0, _srcH, dst, dstStride);

    CVPixelBufferRef px = NULL;
    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(_srcW),
        (id)kCVPixelBufferHeightKey: @(_srcH),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    if (CVPixelBufferCreate(kCFAllocatorDefault, (size_t)_srcW, (size_t)_srcH,
                            kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attrs, &px) != kCVReturnSuccess || !px) {
        [_lock unlock];
        return;
    }

    CVPixelBufferLockBaseAddress(px, 0);
    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(px);
    size_t bpr = CVPixelBufferGetBytesPerRow(px);
    size_t rowBytes = MIN((size_t)_srcW * 4u, bpr);
    for (int y = 0; y < _srcH; y++) {
        memcpy(base + (size_t)y * bpr, _bgra + (size_t)y * (size_t)(_srcW * 4), rowBytes);
    }
    CVPixelBufferUnlockBaseAddress(px, 0);

    if (_latest) CVPixelBufferRelease(_latest);
    _latest = px;
    self.decodedFrames = self.decodedFrames + 1;

    [_lock unlock];
}

#pragma mark - 取帧

- (NSString *)lastReason { return _lastReason ?: @"-"; }

- (CVPixelBufferRef)copyNextFrameScaledTo:(CGSize)targetSize CF_RETURNS_RETAINED {
    [_lock lock];

    if (!_latest) {
        _lastReason = self.running ? @"解码还没出帧" : @"未连接";
        [_lock unlock];
        return NULL;
    }
    CVPixelBufferRef src = CVPixelBufferRetain(_latest);

    BOOL needRotate = (_rotation % 360) != 0;
    BOOL needMirror = _mirror;
    CGFloat sw = (CGFloat)CVPixelBufferGetWidth(src);
    CGFloat sh = (CGFloat)CVPixelBufferGetHeight(src);
    BOOL needScale = !CGSizeEqualToSize(targetSize, CGSizeZero) &&
                     (fabs(targetSize.width - sw) > 1.0 || fabs(targetSize.height - sh) > 1.0);

    if (!needRotate && !needMirror && !needScale) {
        [_lock unlock];
        return src;
    }

    CIImage *img = [CIImage imageWithCVPixelBuffer:src];
    if (needScale) {
        img = [img imageByApplyingTransform:CGAffineTransformMakeScale(targetSize.width / sw,
                                                                      targetSize.height / sh)];
    }
    if (needMirror) {
        CGFloat width = needScale ? targetSize.width : sw;
        img = [img imageByApplyingTransform:CGAffineTransformMakeScale(-1, 1)];
        img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(width, 0)];
    }
    if (needRotate) {
        img = [img imageByApplyingTransform:CGAffineTransformMakeRotation((CGFloat)(_rotation * M_PI / 180.0))];
        img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(
            img.extent.origin.x < 0 ? -img.extent.origin.x : 0,
            img.extent.origin.y < 0 ? -img.extent.origin.y : 0)];
    }

    CGSize outSize = needScale ? targetSize : CGSizeMake(sw, sh);
    if (_rotation == 90 || _rotation == 270) outSize = CGSizeMake(outSize.height, outSize.width);
    if (outSize.width < 2 || outSize.height < 2) {
        _lastReason = [NSString stringWithFormat:@"目标尺寸异常 %.0fx%.0f", outSize.width, outSize.height];
        CVPixelBufferRelease(src);
        [_lock unlock];
        return NULL;
    }

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
    if (!_pool) {
        _lastReason = @"像素池创建失败";
    } else if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _pool, &dst) != kCVReturnSuccess || !dst) {
        _lastReason = @"像素池取缓冲失败";
    } else {
        [_ci render:img toCVPixelBuffer:dst
               bounds:CGRectMake(0, 0, outSize.width, outSize.height)
          colorSpace:CGColorSpaceCreateDeviceRGB()];
        _lastReason = @"ok";
    }
    CVPixelBufferRelease(src);
    [_lock unlock];
    return dst;
}

#pragma mark - 停止

- (void)stop {
    _stopRequested = YES;
    self.running = NO;

    [_lock lock];
    if (_sws) { sws_freeContext(_sws); _sws = NULL; }
    if (_bgra) { free(_bgra); _bgra = NULL; _bgraSize = 0; }
    if (_latest) { CVPixelBufferRelease(_latest); _latest = NULL; }
    if (_pool) { CVPixelBufferPoolRelease(_pool); _pool = NULL; }
    [_lock unlock];

    // 解码线程还在跑时不能关上下文（它可能正卡在 av_read_frame）。
    // 由 decodeLoop 退出时自行释放。
    if (!_loopActive) {
        if (_dec) { avcodec_free_context(&_dec); _dec = NULL; }
        if (_fmt) { avformat_close_input(&_fmt); _fmt = NULL; }
    }

    self.urlString = nil;
}

@end
