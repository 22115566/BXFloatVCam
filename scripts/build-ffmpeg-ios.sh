#!/bin/bash
#
# build-ffmpeg-ios.sh —— 为 arm64 iOS 交叉编译最小 FFmpeg（只保留 RTSP + H.264/HEVC 解码）
#
# 产物：vendor/ffmpeg-ios/{include,lib}
# 用法：在仓库根目录执行  ./scripts/build-ffmpeg-ios.sh
#
set -euo pipefail

FFMPEG_VER="${FFMPEG_VER:-7.1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)/vendor"
PREFIX="$ROOT/ffmpeg-ios"
SRC="$ROOT/ffmpeg-$FFMPEG_VER"

mkdir -p "$ROOT"

if [ ! -d "$SRC" ]; then
  echo "==> 下载 ffmpeg $FFMPEG_VER"
  curl -fL -o "$ROOT/ffmpeg.tar.xz" "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VER}.tar.xz"
  tar xf "$ROOT/ffmpeg.tar.xz" -C "$ROOT"
fi

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CC="$(xcrun -f clang)"

cd "$SRC"

echo "==> configure (arm64, iphoneos, minimal)"
./configure \
  --prefix="$PREFIX" \
  --arch=arm64 \
  --target-os=darwin \
  --cc="$CC" \
  --sysroot="$SDK" \
  --enable-cross-compile \
  --disable-everything \
  --disable-programs --disable-doc --disable-avdevice --disable-avfilter \
  --enable-swresample --disable-postproc --disable-debug --disable-stripping \
  --disable-autodetect --disable-iconv --disable-zlib --disable-bzlib --disable-lzma \
  --enable-network \
  --enable-protocol=file,http,https,tcp,udp,rtp,rtsp \
  --enable-demuxer=rtsp,h264,hevc,mpegts,mov,image2 \
  --enable-parser=h264,hevc \
  --enable-decoder=h264,hevc,mjpeg \
  --enable-encoder=mjpeg \
  --enable-muxer=image2 \
  --enable-swscale \
  --enable-avformat --enable-avcodec --enable-avutil \
  --enable-pic \
  --extra-cflags="-arch arm64 -mios-version-min=14.0 -O2" \
  --extra-ldflags="-arch arm64 -mios-version-min=14.0"

echo "==> make"
make -j"$(sysctl -n hw.ncpu)"

echo "==> install"
make install

echo "==> 产物："
ls -lh "$PREFIX/lib" | sed -n '1,12p'
