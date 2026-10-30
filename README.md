# BXFloatVCam —— 虚拟摄像头（免费版）

和「百相」同类的功能，自己写的实现：**把摄像头画面替换成本地视频**，
可注入抖音 / 快手 / 微信 / 小红书。

无卡密、无联网、无授权校验。

## 原理

```
App 创建 AVCaptureVideoDataOutput
  ↓
调 setSampleBufferDelegate:queue:     ← 我们劫持这里
  ↓
保存 App 原来的 delegate，改成注册自己
  ↓
摄像头帧到来 → 换成视频帧 → 转发给 App 的 delegate
  ↓
App 收到的是我们的画面
```

关键点：
- **未开启时 100% 直通**，不影响任何行为
- `sampleBufferDelegate` getter 也换回 App 原来的对象，防自查
- 音频不替换，直通

## 结构

```
replica-vcam/
├── Makefile              构建 BXFloatVCam.dylib
├── Tweak.xm              注入入口（constructor 里尽早装 hook）
├── BXCore/               悬浮面板 / 模块注册 / 持久化 / 音量键
├── VCam/
│   ├── BXVideoSource     本地视频 → 逐帧 CVPixelBuffer（循环/镜像/旋转/缩放）
│   └── BXCaptureBridge   delegate 劫持 + 帧替换
├── BXModules/BXModules   面板上的开关
└── .github/workflows     云端编译
```

## 面板功能

| 项 | 说明 |
|---|---|
| 虚拟摄像头 | 总开关 |
| 选择视频 | 从相册/文件里挑 mp4/mov |
| 循环播放 | 播完重头 |
| 水平镜像 | 自拍方向 |
| 旋转 | 0/90/180/270 |
| 运行状态 | 看已替换多少帧，判断有没有生效 |

## 编译

```bash
export THEOS=~/theos
cd replica-vcam
make
# 产物: .theos/obj/arm64/BXFloatVCam.dylib
```

没有 Mac 就用 GitHub Actions，见 `BUILD-CLOUD.md`。

## 注入

TrollStore + [TrollFools](https://github.com/Lessica/TrollFools)：
选目标 App → 注入 `BXFloatVCam.dylib` → 开 App。

## 用法

1. 打开抖音/快手/微信/小红书
2. 右上角有悬浮球，点开
3. 「选择视频」→ 挑一个 mp4
4. 打开「虚拟摄像头」
5. 去开直播/视频通话，画面就是你的视频

## 改哪里

`BXCore/BXConfig.h`：

```objc
static const BOOL kBXAttachEverywhere = YES;   // 调试用；正式改 NO
```

改 `NO` 后只对白名单里的四个 App 生效。

## 已知限制

- 只替换**视频**，音频还是真实麦克风
- 摄像头像素格式如果不是 BGRA，可能显示异常 —— 状态面板会打印格式
- RTSP 流暂未实现（只支持本地文件）
- 部分 App 用的不是 `AVCaptureVideoDataOutput`（少见），注入后无效果
