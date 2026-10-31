//
//  BXVideoSource.m
//

#import "BXVideoSource.h"
#import <Accelerate/Accelerate.h>

static void *kBXPoolKey = &kBXPoolKey;

@interface BXVideoSource ()
@property (nonatomic, strong) AVAsset *asset;
@property (nonatomic, strong) AVAssetReader *reader;
@property (nonatomic, strong) AVAssetReaderTrackOutput *output;
@property (nonatomic, strong) NSLock *lock;
@property (nonatomic, assign) CVPixelBufferPoolRef pool;
@property (nonatomic, assign) CVPixelBufferRef lastFrame;   // 保留上一帧做冻结/缩放源
@end

@implementation BXVideoSource {
    CGSize _size;
    BOOL _loaded;
    CGFloat _duration;
    NSString *_path;
}

@synthesize loaded = _loaded;
@synthesize duration = _duration;
@synthesize path = _path;

- (instancetype)init {
    if (self = [super init]) {
        _lock = [NSLock new];
        _loop = YES;
        _mirror = NO;
        _rotation = 0;
    }
    return self;
}

- (void)dealloc {
    [self unload];
}

#pragma mark - 加载

- (BOOL)loadURL:(NSURL *)url error:(NSError **)error {
    if (!url) return NO;
    [self unload];

    AVAsset *asset = [AVAsset assetWithURL:url];
    NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    if (tracks.count == 0) {
        if (error) *error = [NSError errorWithDomain:@"BXVideoSource" code:1
                                            userInfo:@{NSLocalizedDescriptionKey: @"没有视频轨"}];
        return NO;
    }
    AVAssetTrack *track = tracks.firstObject;

    NSError *err = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&err];
    if (!reader) {
        if (error) *error = err;
        return NO;
    }

    NSDictionary *settings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        @"EnableHardwareAcceleratedVideoDecoder": @YES,   // 百相里有这个 key，走硬件解码
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    AVAssetReaderTrackOutput *out =
        [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track
                                                   outputSettings:settings];
    out.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:out]) {
        if (error) *error = [NSError errorWithDomain:@"BXVideoSource" code:2
                                            userInfo:@{NSLocalizedDescriptionKey: @"无法添加输出"}];
        return NO;
    }
    [reader addOutput:out];

    if (![reader startReading]) {
        if (error) *error = reader.error;
        return NO;
    }

    self.asset = asset;
    self.reader = reader;
    self.output = out;
    _size = track.naturalSize;
    _duration = CMTimeGetSeconds(asset.duration);
    _path = url.path;
    _loaded = YES;

    NSLog(@"[BXFloat][vcam] 已加载视频 %@ %.0fx%.0f 时长 %.1fs",
          url.lastPathComponent, _size.width, _size.height, _duration);
    return YES;
}

- (void)unload {
    [self.lock lock];
    if (self.reader) {
        [self.reader cancelReading];
    }
    self.output = nil;
    self.reader = nil;
    self.asset = nil;
    if (_lastFrame) {
        CVPixelBufferRelease(_lastFrame);
        _lastFrame = NULL;
    }
    _loaded = NO;
    [self.lock unlock];
}

- (BOOL)loaded { return _loaded; }
- (CGSize)size { return _size; }
- (CGFloat)duration { return _duration; }
- (NSString *)path { return _path; }

- (void)rewind {
    [self.lock lock];
    [self _restartReaderLocked];
    [self.lock unlock];
}

- (void)_restartReaderLocked {
    if (!self.asset) return;
    if (self.reader) {
        [self.reader cancelReading];
    }
    NSError *err = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:self.asset error:&err];
    if (!reader) { NSLog(@"[BXFloat][vcam] 重建 reader 失败 %@", err); return; }

    NSArray<AVAssetTrack *> *tracks = [self.asset tracksWithMediaType:AVMediaTypeVideo];
    if (tracks.count == 0) return;

    NSDictionary *settings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        @"EnableHardwareAcceleratedVideoDecoder": @YES,   // 百相里有这个 key，走硬件解码
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    AVAssetReaderTrackOutput *out =
        [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:tracks.firstObject
                                                   outputSettings:settings];
    out.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:out]) return;
    [reader addOutput:out];
    if (![reader startReading]) return;

    self.reader = reader;
    self.output = out;
}

#pragma mark - 取帧

- (CVPixelBufferRef)copyNextFrameScaledTo:(CGSize)targetSize {
    CVPixelBufferRef raw = NULL;

    [self.lock lock];
    if (!self.loaded) { [self.lock unlock]; return NULL; }

    CGFloat duration = _duration;
    while (!raw) {
        CMSampleBufferRef sb = [self.output copyNextSampleBuffer];
        if (sb) {
            raw = CMSampleBufferGetImageBuffer(sb);
            if (raw) CVPixelBufferRetain(raw);
            CFRelease(sb);
            break;
        }
        // 播完了
        if (!self.loop) {
            if (_lastFrame) { raw = CVPixelBufferRetain(_lastFrame); }
            break;
        }
        [self _restartReaderLocked];
        if (!self.output) break;
    }
    (void)duration;
    [self.lock unlock];

    if (!raw) return NULL;

    CVPixelBufferRef out = [self _transform:raw toSize:targetSize];
    CVPixelBufferRelease(raw);

    if (out) {
        if (_lastFrame) CVPixelBufferRelease(_lastFrame);
        _lastFrame = CVPixelBufferRetain(out);
    }
    return out;
}

- (CVPixelBufferRef)copyCurrentFrameScaledTo:(CGSize)targetSize {
    [self.lock lock];
    CVPixelBufferRef src = _lastFrame ? CVPixelBufferRetain(_lastFrame) : NULL;
    [self.lock unlock];
    if (!src) return NULL;
    CVPixelBufferRef out = [self _transform:src toSize:targetSize];
    CVPixelBufferRelease(src);
    return out;
}

#pragma mark - 缩放 / 镜像 / 旋转

- (CVPixelBufferRef)_transform:(CVPixelBufferRef)src toSize:(CGSize)targetSize {
    if (!src) return NULL;

    size_t w = CVPixelBufferGetWidth(src);
    size_t h = CVPixelBufferGetHeight(src);
    NSInteger rot = ((self.rotation % 360) + 360) % 360;

    size_t outW = w, outH = h;
    if (rot == 90 || rot == 270) { outW = h; outH = w; }

    if (!self.mirror && rot == 0 && (CGSizeEqualToSize(targetSize, CGSizeZero) ||
        ((size_t)targetSize.width == w && (size_t)targetSize.height == h))) {
        return CVPixelBufferRetain(src);
    }

    size_t finalW = (targetSize.width > 0)  ? (size_t)targetSize.width  : outW;
    size_t finalH = (targetSize.height > 0) ? (size_t)targetSize.height : outH;

    CVPixelBufferRef dst = [self _newBufferWidth:finalW height:finalH];
    if (!dst) return CVPixelBufferRetain(src);

    CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(dst, 0);

    vImage_Buffer inBuf = {
        .data = CVPixelBufferGetBaseAddress(src),
        .height = h,
        .width = w,
        .rowBytes = CVPixelBufferGetBytesPerRow(src),
    };
    vImage_Buffer dstBuf = {
        .data = CVPixelBufferGetBaseAddress(dst),
        .height = finalH,
        .width = finalW,
        .rowBytes = CVPixelBufferGetBytesPerRow(dst),
    };

    // 1) 旋转 + 镜像到中间缓冲（如需要），2) 缩放到目标尺寸
    vImage_Buffer stage = inBuf;
    CVPixelBufferRef stagePx = NULL;

    BOOL needRot = (rot != 0);
    if (needRot) {
        size_t sw = outW, sh = outH;
        stagePx = [self _newBufferWidth:sw height:sh];
        if (stagePx) {
            CVPixelBufferLockBaseAddress(stagePx, 0);
            vImage_Buffer rbuf = {
                .data = CVPixelBufferGetBaseAddress(stagePx),
                .height = sh,
                .width = sw,
                .rowBytes = CVPixelBufferGetBytesPerRow(stagePx),
            };
            if (rot == 90) {
                vImageRotate90_ARGB8888(&inBuf, &rbuf, kRotate90DegreesClockwise, 0, 0);
            } else if (rot == 180) {
                vImageRotate90_ARGB8888(&inBuf, &rbuf, kRotate180DegreesClockwise, 0, 0);
            } else {
                vImageRotate90_ARGB8888(&inBuf, &rbuf, kRotate270DegreesClockwise, 0, 0);
            }
            CVPixelBufferUnlockBaseAddress(stagePx, 0);
            stage = rbuf;
        }
    }

    if (self.mirror) {
        vImageHorizontalReflect_ARGB8888(&stage, &stage, 0);
        if (!needRot && !stagePx) {
            // 直接在输入上镜像会破坏源数据，改复制到 dst 再镜像
            vImageCopyBuffer(&inBuf, &dstBuf, 4, 0);
            vImageHorizontalReflect_ARGB8888(&dstBuf, &dstBuf, 0);
        }
    }

    if (!(self.mirror && !needRot && !stagePx)) {
        if ((size_t)stage.width == finalW && (size_t)stage.height == finalH) {
            vImageCopyBuffer(&stage, &dstBuf, 4, 0);
        } else {
            vImageScale_ARGB8888(&stage, &dstBuf, 0, 0);
        }
    }

    CVPixelBufferUnlockBaseAddress(dst, 0);
    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    if (stagePx) CVPixelBufferRelease(stagePx);

    return dst;
}

- (CVPixelBufferRef)_newBufferWidth:(size_t)w height:(size_t)h {
    NSDictionary *attrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferWidthKey: @(w),
        (id)kCVPixelBufferHeightKey: @(h),
    };
    CVPixelBufferRef px = NULL;
    CVReturn r = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                     kCVPixelFormatType_32BGRA,
                                     (__bridge CFDictionaryRef)attrs, &px);
    if (r != kCVReturnSuccess) {
        NSLog(@"[BXFloat][vcam] CVPixelBufferCreate 失败 %d", r);
        return NULL;
    }
    return px;
}

@end
