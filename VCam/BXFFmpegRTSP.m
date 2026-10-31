//
//  BXFFmpegRTSP.m —— RTSP 直连（FFmpeg 拆包 + VideoToolbox 硬解）
//
//  照百相的实现：
//    · FFmpeg 只负责 RTSP/RTP 拆包（avformat_open_input / av_read_frame）
//    · 解码交给 VideoToolbox（VTDecompressionSession）→ 硬件解码
//    · 输出直接是 420f 的 CVPixelBuffer，不需要再做像素格式转换
//    · 硬解不可用时自动回退到 FFmpeg 软解
//

#import "BXFFmpegRTSP.h"
#import <CoreMedia/CoreMedia.h>
#import <CoreImage/CoreImage.h>
#import <VideoToolbox/VideoToolbox.h>
#import <QuartzCore/QuartzCore.h>

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>
#include <arpa/inet.h>
#include <unistd.h>

static NSString *BXFFErr(int code) {
    char buf[256] = {0};
    av_strerror(code, buf, sizeof(buf));
    return [NSString stringWithFormat:@"%s(%d)", buf, code];
}

@interface BXFFmpegRTSP () {
    AVFormatContext *_fmt;
    AVCodecContext  *_dec;              // 软解回退时才用
    struct SwsContext *_sws;
    int             _streamIndex;
    int             _srcW, _srcH;
    enum AVPixelFormat _srcFmt;

    CVPixelBufferRef _latest;
    NSLock          *_lock;
    dispatch_queue_t _decodeQueue;
    BOOL            _stopRequested;
    CIContext       *_ci;
    CVPixelBufferPoolRef _pool;
    CGSize          _poolSize;
    uint8_t         *_bgra;
    size_t          _bgraSize;
    BOOL            _loopActive;
    NSString       *_lastReason;
    uint64_t        _generation;

    VTDecompressionSessionRef _vtSession;
    CMVideoFormatDescriptionRef _vtFmt;

    int             _aStreamIndex;
    AVCodecContext *_aDec;
    struct SwrContext *_swr;
    int16_t        *_aRing;
    int16_t        *_aTmp;        // 复用缓冲，避免每帧 malloc
    size_t          _aTmpCap;
    size_t          _aRingFrames;
    size_t          _aFillFrames;
    // 音画同步用的解码帧队列（保留最近若干帧 + 各自 PTS）
    CVPixelBufferRef _qBufs[16];
    CMTime           _qPts[16];
    int              _qHead;
    int              _qCount;

    OSType          _camFmt;      // 摄像头像素格式
    size_t          _camW, _camH; // 摄像头尺寸
    int             _aOutRate;
    int             _aOutCh;
}

- (void)publishHardwareFrame:(CVImageBufferRef)buffer;
- (void)setupVideoToolbox:(AVCodecParameters *)par;
- (void)feedHardware:(AVPacket *)pkt;
- (void)publishFrame:(AVFrame *)frame;
- (void)appendAudioFrame:(AVFrame *)af;
- (void)decodeLoop;
- (BOOL)reopenForReconnect:(NSString *)url;

@property (atomic, assign) BOOL running;
@property (atomic, copy)   NSString *urlString;
@property (atomic, assign) CGSize size;
@property (atomic, assign) NSUInteger decodedFrames;
@property (atomic, assign) NSUInteger droppedFrames;

@end

@implementation BXFFmpegRTSP

#pragma mark - VideoToolbox 输出

static void bx_vt_output(void *refCon, void *frameRefCon,
                         OSStatus status, VTDecodeInfoFlags flags,
                         CVImageBufferRef imageBuffer,
                         CMTime pts, CMTime duration) {
    if (status != noErr || imageBuffer == NULL) return;
    BXFFmpegRTSP *me = (__bridge BXFFmpegRTSP *)refCon;
    [me publishHardwareFrame:imageBuffer];
}

- (void)publishHardwareFrame:(CVImageBufferRef)buffer {
    [self enqueueFrame:buffer pts:kCMTimeInvalid];
}

// 入队：保留最近 16 帧（约 0.5 秒），配合摄像头 PTS 做同步
- (void)enqueueFrame:(CVImageBufferRef)buffer pts:(CMTime)pts {
    if (!buffer) return;
    [_lock lock];

    if (_latest) CVPixelBufferRelease(_latest);
    _latest = (CVPixelBufferRef)CVBufferRetain(buffer);

    if (!CMTIME_IS_VALID(pts)) {
        // 硬解回调拿不到可靠 PTS 时，用主机时间兜底
        pts = CMClockGetTime(CMClockGetHostTimeClock());
    }
    if (_qCount == 16) {
        CVPixelBufferRelease(_qBufs[_qHead]);
        _qPts[_qHead] = kCMTimeInvalid;
        _qBufs[_qHead] = NULL;
        _qHead = (_qHead + 1) % 16;
        _qCount--;
    }
    int slot = (_qHead + _qCount) % 16;
    _qBufs[slot] = (CVPixelBufferRef)CVBufferRetain(buffer);
    _qPts[slot] = pts;
    _qCount++;

    _lastReason = @"硬解ok";
    self.decodedFrames = self.decodedFrames + 1;
    CGSize sz = CGSizeMake(CVPixelBufferGetWidth(_latest), CVPixelBufferGetHeight(_latest));
    [_lock unlock];
    if (sz.width > 0) self.size = sz;
}

// 按摄像头 PTS 挑一帧：取「PTS 最接近且不晚于摄像头时间」的那帧
- (CVPixelBufferRef)dequeueFrameForCameraPTS:(CMTime)cameraPTS CF_RETURNS_RETAINED {
    CVPixelBufferRef chosen = NULL;
    [_lock lock];

    if (_qCount == 0) {
        if (_latest) chosen = CVPixelBufferRetain(_latest);
        [_lock unlock];
        return chosen;
    }

    if (!CMTIME_IS_VALID(cameraPTS)) {
        int slot = (_qHead + _qCount - 1) % 16;
        chosen = CVPixelBufferRetain(_qBufs[slot]);
        [_lock unlock];
        return chosen;
    }

    int pick = -1;
    for (int i = 0; i < _qCount; i++) {
        int slot = (_qHead + i) % 16;
        int cmp = CMTimeCompare(_qPts[slot], cameraPTS);
        if (cmp <= 0) pick = slot;          // 记录最后一个「不晚于摄像头时间」的帧
    }
    if (pick < 0) {
        pick = _qHead;                      // 全都不早于摄像头时间 → 取最早那帧
    }
    chosen = CVPixelBufferRetain(_qBufs[pick]);

    // 丢掉它之前的所有帧，避免队列越拖越旧
    while (_qHead != pick && _qCount > 0) {
        CVPixelBufferRelease(_qBufs[_qHead]);
        _qBufs[_qHead] = NULL;
        _qPts[_qHead] = kCMTimeInvalid;
        _qHead = (_qHead + 1) % 16;
        _qCount--;
    }
    [_lock unlock];
    return chosen;
}

#pragma mark - 生命周期

- (instancetype)init {
    if ((self = [super init])) {
        _lock = [NSLock new];
        _decodeQueue = dispatch_queue_create("bx.rtsp.decode", DISPATCH_QUEUE_SERIAL);
        _ci = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
        _streamIndex = -1;
        _aStreamIndex = -1;
    }
    return self;
}

- (void)dealloc { [self stop]; }

- (BOOL)hasAudio { return _aRing != NULL; }
- (int)audioChannels { return (_aOutCh > 0) ? _aOutCh : 2; }
- (NSString *)lastReason { return _lastReason ?: @"-"; }

#pragma mark - 启动

- (BOOL)startWithURLString:(NSString *)urlString error:(NSError **)error {
    [self stop];
    for (int i = 0; i < 120 && _loopActive; i++) usleep(50 * 1000);
    _generation++;

    if (!urlString.length) {
        if (error) *error = [NSError errorWithDomain:@"BXRTSP" code:1
                                            userInfo:@{NSLocalizedDescriptionKey: @"地址为空"}];
        return NO;
    }

    avformat_network_init();

    AVDictionary *opts = NULL;
    av_dict_set(&opts, "rtsp_transport", "tcp", 0);
    av_dict_set(&opts, "stimeout", "5000000", 0);
    av_dict_set(&opts, "max_delay", "0", 0);
    av_dict_set(&opts, "reorder_queue_size", "0", 0);
    av_dict_set(&opts, "fflags", "nobuffer", 0);

    int ret = avformat_open_input(&_fmt, urlString.UTF8String, NULL, &opts);
    av_dict_free(&opts);
    if (ret < 0 || !_fmt) {
        if (error) *error = [NSError errorWithDomain:@"BXRTSP" code:ret
                                            userInfo:@{NSLocalizedDescriptionKey:
                                                           [NSString stringWithFormat:@"打开流失败 %@", BXFFErr(ret)]}];
        return NO;
    }

    ret = avformat_find_stream_info(_fmt, NULL);
    if (ret < 0) {
        if (error) *error = [NSError errorWithDomain:@"BXRTSP" code:ret
                                            userInfo:@{NSLocalizedDescriptionKey:
                                                           [NSString stringWithFormat:@"读取流信息失败 %@", BXFFErr(ret)]}];
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
    _srcW = st->codecpar->width;
    _srcH = st->codecpar->height;

    if (st->codecpar->codec_id == AV_CODEC_ID_H264) {
        [self setupVideoToolbox:st->codecpar];
    }
    if (!_vtSession) {
        NSLog(@"[BXRTSP] 硬解不可用，回退软解");
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
        _srcFmt = _dec->pix_fmt;
    }

    _aStreamIndex = av_find_best_stream(_fmt, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (_aStreamIndex >= 0) {
        AVStream *ast = _fmt->streams[_aStreamIndex];
        const AVCodec *acodec = avcodec_find_decoder(ast->codecpar->codec_id);
        if (acodec) {
            _aDec = avcodec_alloc_context3(acodec);
            avcodec_parameters_to_context(_aDec, ast->codecpar);
            if (avcodec_open2(_aDec, acodec, NULL) >= 0) {
                struct SwrContext *swr = NULL;
                AVChannelLayout outLayout, inLayout;
                av_channel_layout_default(&outLayout, 2);
                av_channel_layout_copy(&inLayout, &_aDec->ch_layout);
                swr_alloc_set_opts2(&swr, &outLayout, AV_SAMPLE_FMT_S16, 48000,
                                    &inLayout, _aDec->sample_fmt, _aDec->sample_rate, 0, NULL);
                av_channel_layout_uninit(&inLayout);
                av_channel_layout_uninit(&outLayout);
                if (swr && swr_init(swr) >= 0) {
                    _swr = swr;
                    _aOutRate = 48000;
                    _aOutCh = 2;
                    _aRingFrames = 5760;   // ~120ms @48k，限制音画漂移
                    _aRing = (int16_t *)calloc(_aRingFrames * 2, sizeof(int16_t));
                    _aFillFrames = 0;
                } else if (swr) {
                    swr_free(&swr);
                }
            }
        }
    }

    self.urlString = urlString;
    self.running = YES;
    _stopRequested = NO;
    _loopActive = YES;
    self.size = CGSizeMake(_srcW, _srcH);

    NSLog(@"[BXRTSP] 连接成功 %@  %dx%d  解码=%@  音频=%@",
          urlString, _srcW, _srcH,
          _vtSession ? @"VideoToolbox" : @"ffmpeg-sw",
          _aRing ? @"yes" : @"no");

    __weak typeof(self) weakSelf = self;
    dispatch_async(_decodeQueue, ^{ [weakSelf decodeLoop]; });
    return YES;
}

#pragma mark - VideoToolbox 初始化

- (void)setupVideoToolbox:(AVCodecParameters *)par {
    const uint8_t *ed = par->extradata;
    int edSize = par->extradata_size;
    CMFormatDescriptionRef desc = NULL;
    OSStatus st = (OSStatus)-1;

    if (ed && edSize > 7 && ed[0] == 1) {
        int numSPS = ed[5] & 0x1F;
        int idx = 6;
        const uint8_t *params[16] = {0};
        size_t sizes[16] = {0};
        int count = 0;

        for (int i = 0; i < numSPS && idx + 2 <= edSize && count < 16; i++) {
            int len = (ed[idx] << 8) | ed[idx + 1];
            idx += 2;
            if (idx + len > edSize) break;
            params[count] = ed + idx;
            sizes[count] = (size_t)len;
            count++;
            idx += len;
        }
        if (idx + 1 <= edSize) {
            int numPPS = ed[idx];
            idx += 1;
            for (int i = 0; i < numPPS && idx + 2 <= edSize && count < 16; i++) {
                int len = (ed[idx] << 8) | ed[idx + 1];
                idx += 2;
                if (idx + len > edSize) break;
                params[count] = ed + idx;
                sizes[count] = (size_t)len;
                count++;
                idx += len;
            }
        }

        if (count >= 2) {
            st = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                kCFAllocatorDefault, count, params, sizes, 4, &desc);
        }
    }

    if (st != noErr || !desc) {
        NSLog(@"[BXRTSP] SPS/PPS 解析失败 st=%d extradata=%d", (int)st, edSize);
        return;
    }
    _vtFmt = desc;

    // 输出格式/尺寸由 recreateVTSession 按摄像头实际参数决定
    [self recreateVTSession];
}


// 按摄像头实际格式重建 VT 输出：420f(全范围) / 420v(视频范围) 选错会有色阶偏差。
// 摄像头第一次给帧时调用一次即可。
- (void)prepareForCameraFormat:(OSType)fmt width:(size_t)w height:(size_t)h {
    if (fmt != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange &&
        fmt != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
        return;   // 只处理两种常见 YUV
    }
    if (_camFmt == fmt && _camW == w && _camH == h) return;

    _camFmt = fmt;
    _camW = w;
    _camH = h;

    if (!_vtFmt) return;     // 还没解析出 SPS/PPS，等 setupVideoToolbox 时用新值
    [self recreateVTSession];
}

- (void)recreateVTSession {
    if (_vtSession) {
        VTDecompressionSessionWaitForAsynchronousFrames(_vtSession);
        VTDecompressionSessionInvalidate(_vtSession);
        CFRelease(_vtSession);
        _vtSession = NULL;
    }
    if (!_vtFmt) return;

    NSDictionary *dstAttrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(_camFmt ? _camFmt : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
        (id)kCVPixelBufferWidthKey: @(_camW ? _camW : (_srcW > 0 ? _srcW : 720)),
        (id)kCVPixelBufferHeightKey: @(_camH ? _camH : (_srcH > 0 ? _srcH : 1280)),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };

    VTDecompressionOutputCallbackRecord cb;
    cb.decompressionOutputCallback = bx_vt_output;
    cb.decompressionOutputRefCon = (__bridge void *)self;

    OSStatus cs = VTDecompressionSessionCreate(kCFAllocatorDefault, _vtFmt, NULL,
                                               (__bridge CFDictionaryRef)dstAttrs, &cb, &_vtSession);
    if (cs != noErr || !_vtSession) {
        NSLog(@"[BXRTSP] VT 重建失败 st=%d", (int)cs);
        _vtSession = NULL;
    } else {
        VTSessionSetProperty(_vtSession, kVTDecompressionPropertyKey_RealTime,
                             (__bridge CFTypeRef)@YES);
        NSLog(@"[BXRTSP] VT 输出格式对齐摄像头 %c%c%c%c %zux%zu",
              (char)(_camFmt >> 24), (char)(_camFmt >> 16), (char)(_camFmt >> 8), (char)_camFmt,
              (size_t)_camW, (size_t)_camH);
    }
}

#pragma mark - 拆包循环

- (void)decodeLoop {
    AVPacket *pkt = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    NSString *url = self.urlString;
    uint64_t myGen = _generation;
    int reconnect = 0;

    while (!_stopRequested && _fmt && pkt) {
        int ret = av_read_frame(_fmt, pkt);
        if (ret < 0) {
            if (ret == AVERROR(EAGAIN)) { usleep(2000); continue; }
            NSLog(@"[BXRTSP] 读包失败 %@，重连第 %d 次", BXFFErr(ret), reconnect);
            if (_stopRequested || !url.length || reconnect >= 30) break;
            reconnect++;
            // 指数退避：1s, 2s, 4s, 8s，之后固定 15s —— 服务端重启时不用一直猛撞
            int waitSec = (reconnect >= 4) ? 15 : (1 << (reconnect - 1));
            NSLog(@"[BXRTSP] 第 %d 次重连，等待 %ds", reconnect, waitSec);
            usleep((useconds_t)waitSec * 1000 * 1000);
            if (myGen != _generation) break;
            if (_dec) { avcodec_free_context(&_dec); _dec = NULL; }
            if (![self reopenForReconnect:url]) break;
            continue;
        }
        reconnect = 0;

        if (pkt->stream_index == _aStreamIndex && _aDec && _swr) {
            if (avcodec_send_packet(_aDec, pkt) == 0) {
                AVFrame *af = av_frame_alloc();
                while (avcodec_receive_frame(_aDec, af) == 0) {
                    [self appendAudioFrame:af];
                    av_frame_unref(af);
                }
                av_frame_free(&af);
            }
            av_packet_unref(pkt);
            continue;
        }

        if (pkt->stream_index == _streamIndex) {
            if (_vtSession) {
                [self feedHardware:pkt];
            } else if (_dec) {
                if (avcodec_send_packet(_dec, pkt) == 0) {
                    while (avcodec_receive_frame(_dec, frame) == 0) {
                        [self publishFrame:frame];
                        av_frame_unref(frame);
                    }
                }
            }
        }
        av_packet_unref(pkt);
    }

    if (frame) av_frame_free(&frame);
    if (pkt) av_packet_free(&pkt);

    if (myGen == _generation) {
        if (_dec) { avcodec_free_context(&_dec); _dec = NULL; }
        if (_aDec) { avcodec_free_context(&_aDec); _aDec = NULL; }
        if (_swr) { swr_free(&_swr); _swr = NULL; }
        if (_aRing) { free(_aRing); _aRing = NULL; }
        if (_aTmp) { free(_aTmp); _aTmp = NULL; _aTmpCap = 0; }
        _aFillFrames = 0;
        if (_fmt) { avformat_close_input(&_fmt); _fmt = NULL; }
        _loopActive = NO;
    }
}

// Annex-B / AVCC 统一转成 AVCC（4 字节长度前缀），再喂给 VT
- (void)feedHardware:(AVPacket *)pkt {
    const uint8_t *data = pkt->data;
    int size = pkt->size;
    if (!data || size < 5 || !_vtFmt) return;

    BOOL annexB = (data[0] == 0 && data[1] == 0 &&
                   (data[2] == 1 || (data[2] == 0 && data[3] == 1)));

    NSMutableData *avcc = [NSMutableData dataWithCapacity:(NSUInteger)size + 16];

    if (annexB) {
        int i = 0;
        while (i + 3 < size) {
            int nalStart = -1;
            int scLen = 0;
            if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1) {
                nalStart = i + 3; scLen = 3;
            } else if (i + 4 < size && data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 0 && data[i + 3] == 1) {
                nalStart = i + 4; scLen = 4;
            }
            if (nalStart < 0) { i++; continue; }

            int next = size;
            for (int j = nalStart; j + 2 < size; j++) {
                if (data[j] == 0 && data[j + 1] == 0 &&
                    (data[j + 2] == 1 || (j + 3 < size && data[j + 2] == 0 && data[j + 3] == 1))) {
                    next = j;
                    break;
                }
            }
            int len = next - nalStart;
            if (len > 0) {
                uint32_t be = htonl((uint32_t)len);
                [avcc appendBytes:&be length:4];
                [avcc appendBytes:data + nalStart length:(NSUInteger)len];
            }
            i = next + (next < size ? 0 : 0);
            if (next <= nalStart) i = nalStart;
        }
    } else {
        [avcc appendBytes:data length:(NSUInteger)size];
    }

    if (avcc.length == 0) return;

    CMBlockBufferRef block = NULL;
    OSStatus bs = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, avcc.length,
                                                     kCFAllocatorDefault, NULL, 0, avcc.length,
                                                     kCMBlockBufferAssureMemoryNowFlag, &block);
    if (bs != noErr || !block) return;
    CMBlockBufferReplaceDataBytes(avcc.bytes, block, 0, avcc.length);

    CMTime ts = kCMTimeInvalid;
    AVRational tb = _fmt->streams[_streamIndex]->time_base;
    if (pkt->pts != AV_NOPTS_VALUE && tb.den > 0) {
        ts = CMTimeMake(pkt->pts * (int64_t)tb.num, tb.den);
    }
    if (!CMTIME_IS_VALID(ts)) ts = CMClockGetTime(CMClockGetHostTimeClock());

    CMSampleTimingInfo timing = { .duration = CMTimeMake(1, 30),
                                  .presentationTimeStamp = ts,
                                  .decodeTimeStamp = kCMTimeInvalid };
    CMSampleBufferRef sbuf = NULL;
    size_t sampleSize = avcc.length;
    OSStatus st = CMSampleBufferCreateReady(kCFAllocatorDefault, block, _vtFmt, 1, 1,
                                            &timing, 1, &sampleSize, &sbuf);
    CFRelease(block);
    if (st != noErr || !sbuf) {
        static int c = 0;
        if (c++ < 5) NSLog(@"[BXRTSP] 造 sample buffer 失败 st=%d", (int)st);
        return;
    }

    VTDecodeInfoFlags info = 0;
    VTDecompressionSessionDecodeFrame(_vtSession, sbuf,
                                      kVTDecodeFrame_EnableAsynchronousDecompression, NULL, &info);
    CFRelease(sbuf);
}

#pragma mark - 软解回退

- (void)publishFrame:(AVFrame *)frame {
    if (!frame || frame->width <= 0) return;
    [_lock lock];
    if (!_sws || frame->width != _srcW || frame->height != _srcH) {
        if (_sws) { sws_freeContext(_sws); _sws = NULL; }
        _srcW = frame->width;
        _srcH = frame->height;
        _srcFmt = (enum AVPixelFormat)frame->format;
        _sws = sws_getContext(_srcW, _srcH, _srcFmt, _srcW, _srcH, AV_PIX_FMT_BGRA,
                              SWS_BILINEAR, NULL, NULL, NULL);
    }
    if (!_sws) { [_lock unlock]; return; }

    size_t need = (size_t)_srcW * 4 * (size_t)_srcH;
    if (!_bgra || _bgraSize < need) {
        uint8_t *nb = realloc(_bgra, need);
        if (!nb) { [_lock unlock]; return; }
        _bgra = nb;
        _bgraSize = need;
    }
    uint8_t *dst[4] = { _bgra, NULL, NULL, NULL };
    int dstStride[4] = { _srcW * 4, 0, 0, 0 };
    sws_scale(_sws, (const uint8_t *const *)frame->data, frame->linesize, 0, _srcH, dst, dstStride);

    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(_srcW),
        (id)kCVPixelBufferHeightKey: @(_srcH),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVPixelBufferRef px = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, (size_t)_srcW, (size_t)_srcH,
                            kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attrs, &px) != kCVReturnSuccess || !px) {
        [_lock unlock];
        return;
    }
    CVPixelBufferLockBaseAddress(px, 0);
    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(px);
    size_t bpr = CVPixelBufferGetBytesPerRow(px);
    for (int y = 0; y < _srcH; y++) {
        memcpy(base + (size_t)y * bpr, _bgra + (size_t)y * (size_t)(_srcW * 4),
               MIN((size_t)_srcW * 4, bpr));
    }
    CVPixelBufferUnlockBaseAddress(px, 0);

    if (_latest) CVPixelBufferRelease(_latest);
    _latest = px;
    _lastReason = @"软解ok";
    self.decodedFrames = self.decodedFrames + 1;
    [_lock unlock];
}

#pragma mark - 取帧

- (CVPixelBufferRef)copyFrameForCameraPTS:(CMTime)cameraPTS
                             scaledTo:(CGSize)targetSize CF_RETURNS_RETAINED {
    CVPixelBufferRef picked = [self dequeueFrameForCameraPTS:cameraPTS];
    if (!picked) return NULL;
    CVPixelBufferRef out = [self transformBuffer:picked toSize:targetSize];
    CVPixelBufferRelease(picked);
    return out;
}

- (CVPixelBufferRef)copyNextFrameScaledTo:(CGSize)targetSize CF_RETURNS_RETAINED {
    [_lock lock];
    if (!_latest) {
        _lastReason = self.running ? @"解码还没出帧" : @"未连接";
        [_lock unlock];
        return NULL;
    }
    CVPixelBufferRef src = CVPixelBufferRetain(_latest);
    [_lock unlock];
    CVPixelBufferRef out = [self transformBuffer:src toSize:targetSize];
    CVPixelBufferRelease(src);
    return out;
}

// 缩放 / 镜像 / 旋转（不含加锁，调用方负责持有 src）
// 像素池缓存：每帧新建池是卡顿的主因（30fps × 创建/销毁）
- (CVPixelBufferPoolRef)poolForSize:(CGSize)size format:(OSType)fmt {
    static CVPixelBufferPoolRef sPool = NULL;
    static CGSize sSize = {0, 0};
    static OSType sFmt = 0;

    if (sPool && CGSizeEqualToSize(sSize, size) && sFmt == fmt) return sPool;

    @synchronized (self) {
        if (sPool) { CVPixelBufferPoolRelease(sPool); sPool = NULL; }
        NSDictionary *attrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(fmt),
            (id)kCVPixelBufferWidthKey: @(size.width),
            (id)kCVPixelBufferHeightKey: @(size.height),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        };
        CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)attrs, &sPool);
        sSize = size;
        sFmt = fmt;
        return sPool;
    }
}

// 硬件缩放（百相用的就是 VTPixelTransferSession）
// 注意：流通常是 1280x720 横向、摄像头是 720x1280 竖向，
// 直接拉伸会把人压扁，所以开启 letterbox（等比缩放 + 黑边）。
- (BOOL)transferFrom:(CVPixelBufferRef)src to:(CVPixelBufferRef)dst {
    static VTPixelTransferSessionRef sTransfer = NULL;
    if (!sTransfer) {
        if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &sTransfer) != noErr || !sTransfer) {
            return NO;
        }
        // 照抄百相：导入表里就是这两个常量
        //   _kVTPixelTransferPropertyKey_ScalingMode
        //   _kVTScalingMode_CropSourceToCleanAperture
        // 即「裁剪填充」：等比放大到铺满、多余部分裁掉，不变形、无黑边。
        VTSessionSetProperty(sTransfer,
                             kVTPixelTransferPropertyKey_ScalingMode,
                             kVTScalingMode_CropSourceToCleanAperture);
    }
    return VTPixelTransferSessionTransferImage(sTransfer, src, dst) == noErr;
}

// 缩放 / 镜像 / 旋转（不含加锁，调用方负责持有 src）
- (CVPixelBufferRef)transformBuffer:(CVPixelBufferRef)src
                             toSize:(CGSize)targetSize CF_RETURNS_RETAINED {
    if (!src) return NULL;

    BOOL needRotate = (_rotation % 360) != 0;
    BOOL needMirror = _mirror;
    CGFloat sw = (CGFloat)CVPixelBufferGetWidth(src);
    CGFloat sh = (CGFloat)CVPixelBufferGetHeight(src);
    BOOL needScale = !CGSizeEqualToSize(targetSize, CGSizeZero) &&
                     (fabs(targetSize.width - sw) > 1.0 || fabs(targetSize.height - sh) > 1.0);

    // 尺寸/方向都一样：零拷贝直接返回
    if (!needRotate && !needMirror && !needScale) {
        return (CVPixelBufferRef)CFRetain(src);
    }

    OSType pf = self.targetFormat ? self.targetFormat : kCVPixelFormatType_32BGRA;
    CGSize outSize = needScale ? targetSize : CGSizeMake(sw, sh);
    if (_rotation == 90 || _rotation == 270) outSize = CGSizeMake(outSize.height, outSize.width);
    if (outSize.width < 2 || outSize.height < 2) return NULL;

    CFTimeInterval t0 = CACurrentMediaTime();

    CVPixelBufferPoolRef pool = [self poolForSize:outSize format:pf];
    if (!pool) return NULL;

    CVPixelBufferRef dst = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &dst) != kCVReturnSuccess || !dst) {
        return NULL;
    }

    // 只需要缩放、且两边都是 420f：走硬件通道，不碰 CIContext
    OSType srcFmt = CVPixelBufferGetPixelFormatType(src);
    if (needScale && !needRotate && !needMirror &&
        srcFmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange &&
        pf == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
        if ([self transferFrom:src to:dst]) {
            double ms = (CACurrentMediaTime() - t0) * 1000.0;
            [_lock lock];
            _lastReason = [NSString stringWithFormat:@"硬缩放ok %.1fms %0.fx%.0f→%.0fx%.0f",
                           ms, sw, sh, outSize.width, outSize.height];
            [_lock unlock];
            return dst;
        }
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
    [_ci render:img toCVPixelBuffer:dst
           bounds:CGRectMake(0, 0, outSize.width, outSize.height)
       colorSpace:CGColorSpaceCreateDeviceRGB()];

    double ms = (CACurrentMediaTime() - t0) * 1000.0;
    [_lock lock];
    _lastReason = [NSString stringWithFormat:@"CIContext缩放 %.1fms", ms];
    [_lock unlock];
    return dst;
}

#pragma mark - 音频

- (void)configureAudioSampleRate:(double)rate channels:(int)channels {
    if (rate < 8000 || rate > 192000) return;
    if (channels < 1 || channels > 8) return;
    if (!_aDec) return;

    [_lock lock];
    if (_swr) { swr_free(&_swr); _swr = NULL; }
    struct SwrContext *swr = NULL;
    AVChannelLayout outLayout, inLayout;
    av_channel_layout_default(&outLayout, channels);
    av_channel_layout_copy(&inLayout, &_aDec->ch_layout);
    int rc = swr_alloc_set_opts2(&swr, &outLayout, AV_SAMPLE_FMT_S16, (int)rate,
                                 &inLayout, _aDec->sample_fmt, _aDec->sample_rate, 0, NULL);
    av_channel_layout_uninit(&inLayout);
    av_channel_layout_uninit(&outLayout);
    if (rc == 0 && swr && swr_init(swr) >= 0) {
        _swr = swr;
        _aOutRate = (int)rate;
        _aOutCh = channels;
        NSLog(@"[BXRTSP] 音频目标对齐摄像头: %dHz %dch", (int)rate, channels);
    } else if (swr) {
        swr_free(&swr);
    }
    [_lock unlock];
}

- (void)appendAudioFrame:(AVFrame *)af {
    if (!_swr || !_aRing) return;
    int maxOut = swr_get_out_samples(_swr, af->nb_samples);
    if (maxOut <= 0) return;
    int ch = (_aOutCh > 0) ? _aOutCh : 2;
    size_t needBytes = (size_t)maxOut * ch * sizeof(int16_t);
    if (!_aTmp || _aTmpCap < needBytes) {
        int16_t *nb = (int16_t *)realloc(_aTmp, needBytes);
        if (!nb) return;
        _aTmp = nb;
        _aTmpCap = needBytes;
    }
    int16_t *tmp = _aTmp;
    uint8_t *outPtr[1] = { (uint8_t *)tmp };
    int got = swr_convert(_swr, outPtr, maxOut, (const uint8_t **)af->extended_data, af->nb_samples);
    if (got > 0) {
        [_lock lock];
        if (_aRing) {
            size_t need = (size_t)got;
            if (need >= _aRingFrames) need = _aRingFrames;
            if (_aFillFrames + need > _aRingFrames) {
                size_t drop = _aFillFrames + need - _aRingFrames;
                if (drop > _aFillFrames) drop = _aFillFrames;
                memmove(_aRing, _aRing + drop * ch, (_aFillFrames - drop) * ch * sizeof(int16_t));
                _aFillFrames -= drop;
            }
            memcpy(_aRing + _aFillFrames * ch, tmp + (got - (int)need) * ch, need * ch * sizeof(int16_t));
            _aFillFrames += need;
        }
        [_lock unlock];
    }
}

- (NSUInteger)copyAudioS16:(int16_t *)dst maxFrames:(NSUInteger)maxFrames {
    if (!dst || maxFrames == 0) return 0;
    int ch = (_aOutCh > 0) ? _aOutCh : 2;
    NSUInteger n = 0;
    [_lock lock];
    if (_aRing && _aFillFrames > 0) {
        n = MIN(maxFrames, _aFillFrames);
        memcpy(dst, _aRing, n * ch * sizeof(int16_t));
        if (n < _aFillFrames) {
            memmove(_aRing, _aRing + n * ch, (_aFillFrames - n) * ch * sizeof(int16_t));
        }
        _aFillFrames -= n;
    }
    [_lock unlock];
    return n;
}

#pragma mark - 重连 / 停止

- (BOOL)reopenForReconnect:(NSString *)url {
    if (_stopRequested || !url.length) return NO;
    AVDictionary *opts = NULL;
    av_dict_set(&opts, "rtsp_transport", "tcp", 0);
    av_dict_set(&opts, "stimeout", "5000000", 0);
    av_dict_set(&opts, "fflags", "nobuffer", 0);
    if (avformat_open_input(&_fmt, url.UTF8String, NULL, &opts) < 0 || !_fmt) {
        av_dict_free(&opts);
        return NO;
    }
    av_dict_free(&opts);
    if (avformat_find_stream_info(_fmt, NULL) < 0) return NO;

    _streamIndex = av_find_best_stream(_fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (_streamIndex < 0) return NO;

    if (!_vtSession) {
        AVStream *st = _fmt->streams[_streamIndex];
        const AVCodec *codec = avcodec_find_decoder(st->codecpar->codec_id);
        if (!codec) return NO;
        _dec = avcodec_alloc_context3(codec);
        avcodec_parameters_to_context(_dec, st->codecpar);
        _dec->thread_count = 2;
        _dec->flags |= AV_CODEC_FLAG_LOW_DELAY;
        if (avcodec_open2(_dec, codec, NULL) < 0) return NO;
    }
    NSLog(@"[BXRTSP] 重连成功 %@", url);
    return YES;
}

- (void)stop {
    _stopRequested = YES;
    self.running = NO;

    if (_vtSession) {
        VTDecompressionSessionWaitForAsynchronousFrames(_vtSession);
        VTDecompressionSessionInvalidate(_vtSession);
        CFRelease(_vtSession);
        _vtSession = NULL;
    }
    if (_vtFmt) { CFRelease(_vtFmt); _vtFmt = NULL; }

    [_lock lock];
    if (_sws) { sws_freeContext(_sws); _sws = NULL; }
    if (_bgra) { free(_bgra); _bgra = NULL; _bgraSize = 0; }
    if (_latest) { CVPixelBufferRelease(_latest); _latest = NULL; }
    if (_pool) { CVPixelBufferPoolRelease(_pool); _pool = NULL; }
    [_lock unlock];

    if (!_loopActive) {
        if (_dec) { avcodec_free_context(&_dec); _dec = NULL; }
        if (_aDec) { avcodec_free_context(&_aDec); _aDec = NULL; }
        if (_swr) { swr_free(&_swr); _swr = NULL; }
        if (_aRing) { free(_aRing); _aRing = NULL; }
        _aFillFrames = 0;
        if (_fmt) { avformat_close_input(&_fmt); _fmt = NULL; }
    }
    self.urlString = nil;
}

@end
