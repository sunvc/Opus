@preconcurrency import AVFoundation
import Foundation
import OpusObjC

public typealias OpusEncoderState = [String: Any]

public enum OpusManagerError: LocalizedError {
    case failedToCreateTargetFormat
    case failedToStartWriter
    case failedToAppendBuffer
    case failedToResumeWriter
    case encoderAlreadyFinished
    case failedToCreateConverter
    case failedToCreateOutputBuffer
    case failedToExtractPCMData
    case failedToConvertBuffer(String)

    public var errorDescription: String? {
        switch self {
        case .failedToCreateTargetFormat:
            return "Failed to create target audio format."
        case .failedToStartWriter:
            return "Failed to start Opus writer."
        case .failedToAppendBuffer:
            return "Failed to append PCM buffer to Opus writer."
        case .failedToResumeWriter:
            return "Failed to resume Opus writer."
        case .encoderAlreadyFinished:
            return "Opus manager has already finished encoding."
        case .failedToCreateConverter:
            return "Failed to create audio converter."
        case .failedToCreateOutputBuffer:
            return "Failed to create converted audio buffer."
        case .failedToExtractPCMData:
            return "Failed to extract PCM bytes from audio buffer."
        case .failedToConvertBuffer(let message):
            return "Failed to convert audio buffer: \(message)"
        }
    }
}

public enum OpusApplication: Sendable {
    case audio
    case voip

    fileprivate var writerApplication: OggOpusWriterApplication {
        switch self {
        case .audio:
            return .audio
        case .voip:
            return .voip
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

public final class OpusManager {
    public let sampleRate: Int
    public let bitrate: Int
    public let application: OpusApplication

    private let writer: OggOpusWriter
    private var dataItem: DataItem
    private let targetFormat: AVAudioFormat
    private let frameByteCount: Int

    private var converter: AVAudioConverter?
    private var converterSourceSignature: AudioFormatSignature?
    private var pendingPCMData = Data()
    private var isFinished = false

    public convenience init(
        sampleRate: Int,
        bitrate: Int,
        application: OpusApplication = .audio
    ) throws {
        try self.init(
            sampleRate: sampleRate,
            bitrate: bitrate,
            application: application,
            initialEncodedData: Data(),
            appendToExistingData: false
        )
    }

    public convenience init(
        appending encodedData: Data,
        sampleRate: Int,
        bitrate: Int,
        application: OpusApplication = .audio
    ) throws {
        try self.init(
            sampleRate: sampleRate,
            bitrate: bitrate,
            application: application,
            initialEncodedData: encodedData,
            appendToExistingData: true
        )
    }

    private init(
        sampleRate: Int,
        bitrate: Int,
        application: OpusApplication,
        initialEncodedData: Data,
        appendToExistingData: Bool
    ) throws {
        let resolvedSampleRate = sampleRate > 0 ? sampleRate : 48_000
        let resolvedBitrate = bitrate > 0 ? bitrate : 30_000

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(resolvedSampleRate),
            channels: 1,
            interleaved: true
        ) else {
            throw OpusManagerError.failedToCreateTargetFormat
        }

        self.sampleRate = resolvedSampleRate
        self.bitrate = resolvedBitrate
        self.application = application
        self.targetFormat = targetFormat
        self.frameByteCount = (resolvedSampleRate / 50) * MemoryLayout<Int16>.size
        self.dataItem = DataItem(data: initialEncodedData)
        self.writer = OggOpusWriter(
            inputSampleRate: resolvedSampleRate,
            bitrate: resolvedBitrate,
            application: application.writerApplication
        )

        let started = appendToExistingData
            ? writer.beginAppend(with: dataItem)
            : writer.begin(with: dataItem)

        guard started else {
            throw OpusManagerError.failedToStartWriter
        }
    }

    public var encodedData: Data {
        dataItem.data()
    }

    public var encodedBytes: Int {
        Int(writer.encodedBytes())
    }

    public var encodedDuration: TimeInterval {
        writer.encodedDuration()
    }

    public func append(buffer: AVAudioPCMBuffer) throws {
        guard !isFinished else {
            throw OpusManagerError.encoderAlreadyFinished
        }

        guard buffer.frameLength > 0 else {
            return
        }

        let pcmBuffer = try makePCM16MonoBuffer(from: buffer)
        pendingPCMData.append(try pcmData(from: pcmBuffer))
        try flushPendingFrames(keepTailForFinish: true)
    }

    public func finish() throws -> Data {
        if isFinished {
            return dataItem.data()
        }

        if !pendingPCMData.isEmpty {
            try flushPendingFrames(keepTailForFinish: false)
        }

        isFinished = true
        return dataItem.data()
    }

    public func pause() -> OpusEncoderState {
        var state = (writer.pause() as? OpusEncoderState) ?? [:]
        state["manager_pendingPCMData"] = pendingPCMData
        state["manager_isFinished"] = isFinished
        return state
    }

    public func resume(from state: OpusEncoderState) throws {
        pendingPCMData = state["manager_pendingPCMData"] as? Data ?? Data()
        isFinished = state["manager_isFinished"] as? Bool ?? false

        guard writer.resume(with: dataItem, encoderState: state) else {
            throw OpusManagerError.failedToResumeWriter
        }
    }

    public func resume(from state: OpusEncoderState, encodedData: Data) throws {
        dataItem = DataItem(data: encodedData)
        converter = nil
        converterSourceSignature = nil
        pendingPCMData = state["manager_pendingPCMData"] as? Data ?? Data()
        isFinished = state["manager_isFinished"] as? Bool ?? false

        guard writer.resume(with: dataItem, encoderState: state) else {
            throw OpusManagerError.failedToResumeWriter
        }
    }

    private func flushPendingFrames(keepTailForFinish: Bool) throws {
        let tailSize = keepTailForFinish ? frameByteCount : 0

        while pendingPCMData.count > tailSize {
            let chunkSize = min(frameByteCount, pendingPCMData.count)
            let isFinalChunk = !keepTailForFinish && pendingPCMData.count <= frameByteCount
            let chunk = pendingPCMData.prefix(chunkSize)

            let success = chunk.withUnsafeBytes { rawBuffer -> Bool in
                guard let baseAddress = rawBuffer.baseAddress else {
                    return false
                }
                let pcmPointer = UnsafeMutablePointer(
                    mutating: baseAddress.assumingMemoryBound(to: UInt8.self)
                )
                return writer.writeFrame(
                    pcmPointer,
                    frameByteCount: UInt(chunkSize),
                    endOfStream: isFinalChunk
                )
            }

            guard success else {
                throw OpusManagerError.failedToAppendBuffer
            }

            pendingPCMData.removeSubrange(0..<chunkSize)
        }
    }

    private func pcmData(from buffer: AVAudioPCMBuffer) throws -> Data {
        let audioBufferList = UnsafeMutableAudioBufferListPointer(
            buffer.mutableAudioBufferList
        )

        guard
            let audioBuffer = audioBufferList.first,
            let rawPointer = audioBuffer.mData,
            audioBuffer.mDataByteSize > 0
        else {
            throw OpusManagerError.failedToExtractPCMData
        }

        return Data(bytes: rawPointer, count: Int(audioBuffer.mDataByteSize))
    }

    private func makePCM16MonoBuffer(from buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if isCompatibleWithTarget(buffer.format) {
            return buffer
        }

        let sourceSignature = AudioFormatSignature(format: buffer.format)
        if converter == nil || converterSourceSignature != sourceSignature {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            converterSourceSignature = sourceSignature
        }

        guard let converter else {
            throw OpusManagerError.failedToCreateConverter
        }

        let sampleRateRatio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(
            max(1, ceil(Double(buffer.frameLength) * sampleRateRatio) + 1)
        )

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputCapacity
        ) else {
            throw OpusManagerError.failedToCreateOutputBuffer
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
            throw OpusManagerError.failedToConvertBuffer(
                conversionError.localizedDescription
            )
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            if outputBuffer.frameLength == 0 {
                throw OpusManagerError.failedToConvertBuffer("Converted buffer is empty.")
            }
            return outputBuffer
        case .error:
            throw OpusManagerError.failedToConvertBuffer("Audio converter returned an error.")
        @unknown default:
            throw OpusManagerError.failedToConvertBuffer("Audio converter returned an unknown status.")
        }
    }

    private func isCompatibleWithTarget(_ format: AVAudioFormat) -> Bool {
        format.commonFormat == targetFormat.commonFormat &&
        format.sampleRate == targetFormat.sampleRate &&
        format.channelCount == targetFormat.channelCount &&
        format.isInterleaved == targetFormat.isInterleaved
    }
}
