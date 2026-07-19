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

    var packetApplication: OpusPacketEncoderApplication {
        switch self {
        case .audio:
            return .audio
        case .voip:
            return .voip
        }
    }
}

public final class OpusManager {
    public let sampleRate: Int
    public let bitrate: Int
    public let application: OpusApplication

    private let writer: OggOpusWriter
    private var dataItem: DataItem
    private let pcmConverter: PCM16MonoAudioBufferConverter
    private let frameByteCount: Int

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

        self.sampleRate = resolvedSampleRate
        self.bitrate = resolvedBitrate
        self.application = application
        self.frameByteCount = (resolvedSampleRate / 50) * MemoryLayout<Int16>.size
        self.dataItem = DataItem(data: initialEncodedData)
        self.writer = OggOpusWriter(
            inputSampleRate: resolvedSampleRate,
            bitrate: resolvedBitrate,
            application: application.writerApplication
        )
        self.pcmConverter = try Self.makePCMConverter(sampleRate: resolvedSampleRate)

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

    private func makePCM16MonoBuffer(from buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        do {
            return try pcmConverter.makePCM16MonoBuffer(from: buffer)
        } catch {
            throw mapPCMError(error)
        }
    }

    private func pcmData(from buffer: AVAudioPCMBuffer) throws -> Data {
        do {
            return try pcmConverter.pcmData(from: buffer)
        } catch {
            throw mapPCMError(error)
        }
    }

    private static func makePCMConverter(sampleRate: Int) throws -> PCM16MonoAudioBufferConverter {
        do {
            return try PCM16MonoAudioBufferConverter(sampleRate: sampleRate)
        } catch {
            throw Self.mapPCMError(error)
        }
    }

    private func mapPCMError(_ error: Error) -> OpusManagerError {
        Self.mapPCMError(error)
    }

    private static func mapPCMError(_ error: Error) -> OpusManagerError {
        guard let error = error as? PCM16MonoAudioError else {
            return .failedToConvertBuffer(error.localizedDescription)
        }

        switch error {
        case .failedToCreateTargetFormat:
            return .failedToCreateTargetFormat
        case .failedToCreateConverter:
            return .failedToCreateConverter
        case .failedToCreateOutputBuffer:
            return .failedToCreateOutputBuffer
        case .failedToExtractPCMData:
            return .failedToExtractPCMData
        case .failedToConvertBuffer(let message):
            return .failedToConvertBuffer(message)
        case .failedToCreatePCMBuffer:
            return .failedToConvertBuffer("Failed to create PCM buffer from decoded data.")
        case .invalidPCMByteCount:
            return .failedToConvertBuffer("PCM data byte count is not aligned to Int16 samples.")
        }
    }
}
