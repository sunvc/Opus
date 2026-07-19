@preconcurrency import AVFoundation
import Foundation

enum PCM16MonoAudioError: LocalizedError {
    case failedToCreateTargetFormat
    case failedToCreateConverter
    case failedToCreateOutputBuffer
    case failedToExtractPCMData
    case failedToConvertBuffer(String)
    case failedToCreatePCMBuffer
    case invalidPCMByteCount

    var errorDescription: String? {
        switch self {
        case .failedToCreateTargetFormat:
            return "Failed to create target audio format."
        case .failedToCreateConverter:
            return "Failed to create audio converter."
        case .failedToCreateOutputBuffer:
            return "Failed to create converted audio buffer."
        case .failedToExtractPCMData:
            return "Failed to extract PCM bytes from audio buffer."
        case .failedToConvertBuffer(let message):
            return "Failed to convert audio buffer: \(message)"
        case .failedToCreatePCMBuffer:
            return "Failed to create PCM buffer from decoded data."
        case .invalidPCMByteCount:
            return "PCM data byte count is not aligned to Int16 samples."
        }
    }
}

private struct AudioFormatSignature: Equatable {
    let commonFormat: AVAudioCommonFormat
    let sampleRate: Double
    let channelCount: AVAudioChannelCount
    let isInterleaved: Bool

    init(format: AVAudioFormat) {
        commonFormat = format.commonFormat
        sampleRate = format.sampleRate
        channelCount = format.channelCount
        isInterleaved = format.isInterleaved
    }
}

private final class ConversionInputBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var didProvideInput = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

final class PCM16MonoAudioBufferConverter {
    let targetFormat: AVAudioFormat

    private var converter: AVAudioConverter?
    private var converterSourceSignature: AudioFormatSignature?

    init(sampleRate: Int) throws {
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: true
        ) else {
            throw PCM16MonoAudioError.failedToCreateTargetFormat
        }

        self.targetFormat = targetFormat
    }

    func makePCM16MonoBuffer(from buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if isCompatibleWithTarget(buffer.format) {
            return buffer
        }

        let sourceSignature = AudioFormatSignature(format: buffer.format)
        if converter == nil || converterSourceSignature != sourceSignature {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            converterSourceSignature = sourceSignature
        }

        guard let converter else {
            throw PCM16MonoAudioError.failedToCreateConverter
        }

        let sampleRateRatio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(
            max(1, ceil(Double(buffer.frameLength) * sampleRateRatio) + 1)
        )

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputCapacity
        ) else {
            throw PCM16MonoAudioError.failedToCreateOutputBuffer
        }

        var conversionError: NSError?
        let inputBox = ConversionInputBox(buffer: buffer)

        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if inputBox.didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }

            inputBox.didProvideInput = true
            outStatus.pointee = .haveData
            return inputBox.buffer
        }

        if let conversionError {
            throw PCM16MonoAudioError.failedToConvertBuffer(
                conversionError.localizedDescription
            )
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            if outputBuffer.frameLength == 0 {
                throw PCM16MonoAudioError.failedToConvertBuffer("Converted buffer is empty.")
            }
            return outputBuffer
        case .error:
            throw PCM16MonoAudioError.failedToConvertBuffer("Audio converter returned an error.")
        @unknown default:
            throw PCM16MonoAudioError.failedToConvertBuffer("Audio converter returned an unknown status.")
        }
    }

    func pcmData(from buffer: AVAudioPCMBuffer) throws -> Data {
        let audioBufferList = UnsafeMutableAudioBufferListPointer(
            buffer.mutableAudioBufferList
        )

        guard
            let audioBuffer = audioBufferList.first,
            let rawPointer = audioBuffer.mData,
            audioBuffer.mDataByteSize > 0
        else {
            throw PCM16MonoAudioError.failedToExtractPCMData
        }

        return Data(bytes: rawPointer, count: Int(audioBuffer.mDataByteSize))
    }

    func makeBuffer(fromPCMData data: Data) throws -> AVAudioPCMBuffer {
        guard data.count.isMultiple(of: MemoryLayout<Int16>.size) else {
            throw PCM16MonoAudioError.invalidPCMByteCount
        }

        let frameLength = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: max(frameLength, 1)
        ) else {
            throw PCM16MonoAudioError.failedToCreatePCMBuffer
        }

        buffer.frameLength = frameLength
        if frameLength > 0 {
            let audioBufferList = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            guard let rawPointer = audioBufferList.first?.mData else {
                throw PCM16MonoAudioError.failedToCreatePCMBuffer
            }

            data.copyBytes(to: rawPointer.assumingMemoryBound(to: UInt8.self), count: data.count)
            audioBufferList[0].mDataByteSize = UInt32(data.count)
        }

        return buffer
    }

    private func isCompatibleWithTarget(_ format: AVAudioFormat) -> Bool {
        format.commonFormat == targetFormat.commonFormat &&
        format.sampleRate == targetFormat.sampleRate &&
        format.channelCount == targetFormat.channelCount &&
        format.isInterleaved == targetFormat.isInterleaved
    }
}
