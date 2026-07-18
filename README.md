# Opus

基于 `libopus` 的 Swift Package，提供可直接在 `iOS`、`iOS Simulator` 和 `macOS` 使用的 `xcframework`，并封装了 Ogg/Opus 的写入与读取能力。

这个仓库的重点不是只暴露底层 C 接口，而是提供一个在 Apple 平台项目里更容易接入的 Ogg/Opus 封装，尤其适合录音、语音消息、语音文件读写这类场景。

## 特性

- 支持 `iOS`、`iOS Simulator`、`macOS`
- 通过 `xcframework` 分发 `libopus`
- 提供 `OggOpusWriter`，支持写入 `.ogg/.opus`
- 提供 `OggOpusReader`，支持读取和拆帧
- 同时支持 `Swift` 和 `Objective-C`
- 可控制编码采样率、码率和 `application` 模式

## 安装

### Swift Package Manager

Xcode 中添加仓库地址：

```text
https://github.com/uuneo/Opus
```

或在 `Package.swift` 中添加：

```swift
.package(url: "https://github.com/uuneo/Opus", from: "1.0.0")
```

把 `Opus` 加入 target 依赖：

```swift
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "Opus", package: "Opus")
    ]
)
```

如果你需要直接访问底层 C 常量或 API，也可以额外依赖 `libopus`：

```swift
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "Opus", package: "Opus"),
        .product(name: "libopus", package: "Opus")
    ]
)
```

## 公开模块

- `Opus`
  - Swift 入口模块，包含 `OpusManager`
- `OpusObjC`
  - 底层 Objective-C 封装，包含 `OggOpusWriter`、`OggOpusReader`、`DataItem`
- `libopus`
  - 底层 `libopus` 二进制模块
- `Encryptor`
  - 仓库内额外暴露的二进制模块，与 Ogg/Opus 编解码本身无直接关系

## 快速开始

### Swift 包装层

```swift
import AVFoundation
import Opus

let encoder = try OpusManager(
    sampleRate: 16000,
    bitrate: 24000,
    application: .voip
)

try encoder.append(buffer: pcmBuffer)

let opusData = try encoder.finish()
```

`OpusManager` 会把传入的 `AVAudioPCMBuffer` 转换为当前编码器需要的单声道 `16-bit PCM`，再交给底层 `OggOpusWriter`。

### Swift 写入 Ogg/Opus

```swift
import OpusObjC

let dataItem = DataItem(data: Data())

let writer = OggOpusWriter(
    inputSampleRate: 16000,
    bitrate: 24000,
    application: .voip
)

guard writer.begin(with: dataItem) else {
    fatalError("Failed to start opus writer")
}

pcmData.withUnsafeBytes { rawBuffer in
    guard let baseAddress = rawBuffer.baseAddress else { return }
    _ = writer.writeFrame(
        baseAddress.assumingMemoryBound(to: UInt8.self),
        frameByteCount: pcmData.count
    )
}

let opusData = dataItem.data()
```

### Swift 追加写入

```swift
import OpusObjC

let existing = DataItem(data: existingOpusData)
let writer = OggOpusWriter(
    inputSampleRate: 16000,
    bitrate: 24000,
    application: .voip
)

guard writer.beginAppend(with: existing) else {
    fatalError("Failed to append opus data")
}
```

### Swift 暂停与恢复

```swift
import OpusObjC

let dataItem = DataItem(data: Data())
let writer = OggOpusWriter(
    inputSampleRate: 16000,
    bitrate: 24000,
    application: .voip
)

guard writer.begin(with: dataItem) else {
    fatalError("Failed to start opus writer")
}

let state = writer.pause()

let resumedWriter = OggOpusWriter(
    inputSampleRate: 16000,
    bitrate: 24000,
    application: .voip
)

guard resumedWriter.resume(with: dataItem, encoderState: state) else {
    fatalError("Failed to resume opus writer")
}
```

### Swift 读取 Ogg/Opus

```swift
import OpusObjC

if let reader = OggOpusReader(path: filePath) {
    var pcmBuffer = [UInt8](repeating: 0, count: 4096)
    let readCount = reader.read(&pcmBuffer, bufSize: Int32(pcmBuffer.count))
    print(readCount)
}
```

### Swift 拆分 Opus 帧

```swift
import OpusObjC

if let frames = OggOpusReader.extractFrames(opusData) {
    for frame in frames {
        print(frame.numSamples, frame.data.count)
    }
}
```

### Objective-C

```objc
#import <OpusObjC/OggOpusWriter.h>
#import <OpusObjC/DataItem.h>

DataItem *dataItem = [[DataItem alloc] initWithData:[NSData data]];
OggOpusWriter *writer =
    [[OggOpusWriter alloc] initWithInputSampleRate:16000
                                           bitrate:24000
                                       application:OggOpusWriterApplicationVoip];

[writer beginWithDataItem:dataItem];
```

## `OggOpusWriter` 参数说明

### `inputSampleRate`

输入 PCM 的采样率。

当前实现要求使用 Opus 支持的标准采样率：

- `8000`
- `12000`
- `16000`
- `24000`
- `48000`

如果传入 `<= 0`，会回退到默认值 `48000`。

### `bitrate`

目标码率，单位是 `bps`。

示例：

- `16000` 表示 `16 kbps`
- `24000` 表示 `24 kbps`
- `32000` 表示 `32 kbps`

如果传入 `<= 0`，会回退到默认值 `30000`。

### `application`

编码模式，对 Swift 暴露为 `OggOpusWriterApplication`：

- `.audio`
  - 更适合音乐、播客、环境声、普通媒体音频
- `.voip`
  - 更适合语音消息、通话、ASR 前的人声编码

默认值是 `.audio`。

## 写入流程

常规写入流程如下：

1. 创建 `DataItem`
2. 创建 `OggOpusWriter`
3. 调用 `begin(with:)`
4. 持续调用 `writeFrame(_:frameByteCount:)`
5. 从 `DataItem` 取出最终的 Ogg/Opus 数据

如果需要在已有 Ogg/Opus 数据后继续写入，可以使用 `beginAppend(with:)`。

如果需要中断后恢复编码，可以使用：

- `pause()`
- `resume(with:encoderState:)`

## 注意事项

- `writeFrame(_:frameByteCount:)` 传入的是 `16-bit PCM` 字节流
- 当前实现默认使用单声道编码
- `application`、`bitrate`、采样率配置会在首次创建、追加写入、恢复状态时统一生效
- 如果你要做语音消息或语音识别前处理，推荐优先使用 `.voip`
- 如果你要做音乐或通用音频存储，推荐优先使用 `.audio`

## 项目结构

```text
.
├── build-opus-xcframework.sh
├── Package.swift
└── Sources
    ├── libopus
    │   └── libopus.xcframework
    └── Opus
        ├── include
        ├── ogg
        ├── opusenc
        └── opusfile
```

## 手动构建 `libopus.xcframework`

1. 下载 [libopus](https://opus-codec.org/downloads/) 源码
2. 将源码放到项目根目录，与 `build-opus-xcframework.sh` 同级
3. 运行脚本：

```bash
chmod +x build-opus-xcframework.sh
./build-opus-xcframework.sh
```

构建结果位于：

```text
Sources/libopus/libopus.xcframework
```

## License

- `libopus` 来自 [Xiph.Org Foundation](https://xiph.org/)，使用 BSD License
- 本仓库中的 Swift/Objective-C 封装代码使用 MIT License

## Credits

- [libopus](https://opus-codec.org/)
- 封装与适配：[@uuneo](https://github.com/uuneo)
