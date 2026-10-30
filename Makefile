#
# BXFloat VCam — 虚拟摄像头（TrollStore / 裸 dylib）
#

TARGET := iphone:clang:latest:14.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = BXFloatVCam

BXFloatVCam_FILES = Tweak.xm \
                    BXCore/BXSwizzle.m \
                    BXCore/BXFloatWindow.m \
                    BXCore/BXFloatMenuController.m \
                    BXCore/BXPreviewWindow.m \
                    BXCore/BXFloatModule.m \
                    BXCore/BXFloatStore.m \
                    BXCore/BXVolumeShortcut.m \
                    VCam/BXVideoSource.m \
                    VCam/BXStreamVideoSource.m \
                    VCam/BXFFmpegRTSP.m \
                    VCam/BXCaptureBridge.m \
                    BXModules/BXModules.m

BXFloatVCam_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)/BXCore -I$(THEOS_PROJECT_DIR)/VCam -Wno-error -Wno-unused-function -Wno-unused-variable
BXFloatVCam_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore CoreImage \
                         AVFoundation CoreMedia CoreVideo Accelerate

FFMPEG_ROOT = $(THEOS_PROJECT_DIR)/vendor/ffmpeg-ios
BXFloatVCam_CFLAGS += -I$(FFMPEG_ROOT)/include
BXFloatVCam_LDFLAGS = -install_name @executable_path/BXFloatVCam.dylib \
                      -L$(FFMPEG_ROOT)/lib -lavformat -lavcodec -lswscale -lavutil \
                      -framework VideoToolbox -framework Security -framework CoreMedia \
                      -framework CoreVideo -framework AudioToolbox

include $(THEOS_MAKE_PATH)/library.mk
