@preconcurrency import AVFoundation
import Foundation
import OpusObjC

public enum OpusRealtimeError: LocalizedError {
    case unsupportedSampleRate(Int)
    case failedToCreateEncoder
    case failedToCreateDecoder
    case failedToEncodePacket
    case failedToDecodePacket
    case invalidFrameDuration(Int)
    case audioConversionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSampleRate(let sampleRate):
            return "Unsupported Opus sample rate: \(sampleRate). Use 8000, 12000, 16000, 24000, or 48000."
        case .failedToCreateEncoder:
            return "Failed to create realtime Opus encoder."
        case .failedToCreateDecoder:
            return "Failed to create realtime Opus decoder."
        case .failedToEncodePacket:
            return "Failed to encode realtime Opus packet."
        case .failedToDecodePacket:
            return "Failed to decode realtime Opus packet."
        case .invalidFrameDuration(let durationMs):
            return "Invalid frame duration: \(durationMs)ms."
        case .audioConversionFailed(let message):
            return message
        }
    }
}

public final class OpusRealtimeEncoder {
    public let sampleRate: Int
    public let bitrate: Int
    public let application: OpusApplication

    public var frameSize: Int {
        Int(encoder.frameSize)
    }

    public var frameByteCount: Int {
        Int(encoder.frameByteCount)
    }

    public var encodedDuration: TimeInterval {
        encoder.encodedDuration
    }

    public var encodedPackets: Int {
        Int(encoder.encodedPackets)
    }

    private let encoder: OpusPacketEncoder
    private let pcmConverter: PCM16MonoAudioBufferConverter
    private var pendingPCMData = Data()

    public init(
        sampleRate: Int,
        bitrate: Int,
        application: OpusApplication = .voip
    ) throws {
        let resolvedSampleRate = sampleRate > 0 ? sampleRate : 48_000
        guard Self.isSupported(sampleRate: resolvedSampleRate) else {
            throw OpusRealtimeError.unsupportedSampleRate(resolvedSampleRate)
        }

        let resolvedBitrate = bitrate > 0 ? bitrate : 30_000
        guard let encoder = OpusPacketEncoder(
            inputSampleRate: resolvedSampleRate,
            bitrate: resolvedBitrate,
            application: application.packetApplication
        ) else {
            throw OpusRealtimeError.failedToCreateEncoder
        }

        do {
            pcmConverter = try PCM16MonoAudioBufferConverter(sampleRate: resolvedSampleRate)
        } catch {
            throw Self.mapPCMError(error)
        }

        self.sampleRate = resolvedSampleRate
        self.bitrate = resolvedBitrate
        self.application = application
        self.encoder = encoder
    }

    public func encode(buffer: AVAudioPCMBuffer) throws -> [Data] {
        guard buffer.frameLength > 0 else {
            return []
        }

        let pcmBuffer: AVAudioPCMBuffer
        let pcmData: Data
        do {
            pcmBuffer = try pcmConverter.makePCM16MonoBuffer(from: buffer)
            pcmData = try pcmConverter.pcmData(from: pcmBuffer)
        } catch {
            throw Self.mapPCMError(error)
        }

        pendingPCMData.append(pcmData)
        return try drainPackets(flushTail: false)
    }

    public func finish() throws -> [Data] {
        try drainPackets(flushTail: true)
    }

    public func reset() {
        pendingPCMData.removeAll(keepingCapacity: false)
        encoder.resetState()
    }

    private func drainPackets(flushTail: Bool) throws -> [Data] {
        let requiredBytes = frameByteCount
        let tailLimit = flushTail ? 0 : requiredBytes
        var packets: [Data] = []

        while pendingPCMData.count > tailLimit {
            let chunkSize = min(requiredBytes, pendingPCMData.count)
            let isFinalChunk = flushTail && pendingPCMData.count <= requiredBytes
            let chunk = pendingPCMData.prefix(chunkSize)

            let packet = chunk.withUnsafeBytes { rawBuffer -> Data? in
                guard let baseAddress = rawBuffer.baseAddress else {
                    return nil
                }

                let pcmPointer = UnsafeMutablePointer(
                    mutating: baseAddress.assumingMemoryBound(to: UInt8.self)
                )

                return encoder.encodeFrame(
                    pcmPointer,
                    frameByteCount: UInt(chunkSize),
                    endOfStream: isFinalChunk
                )
            }

            guard let packet else {
                throw OpusRealtimeError.failedToEncodePacket
            }

            packets.append(packet)
            pendingPCMData.removeSubrange(0..<chunkSize)
        }

        return packets
    }

    static func isSupported(sampleRate: Int) -> Bool {
        [8_000, 12_000, 16_000, 24_000, 48_000].contains(sampleRate)
    }

    static func mapPCMError(_ error: Error) -> OpusRealtimeError {
        if let error = error as? PCM16MonoAudioError {
            return .audioConversionFailed(error.localizedDescription)
        }

        return .audioConversionFailed(error.localizedDescription)
    }
}

public final class OpusRealtimeDecoder {
    public let sampleRate: Int

    public var outputFormat: AVAudioFormat {
        pcmConverter.targetFormat
    }

    private let decoder: OpusPacketDecoder
    private let pcmConverter: PCM16MonoAudioBufferConverter

    public init(sampleRate: Int) throws {
        let resolvedSampleRate = sampleRate > 0 ? sampleRate : 48_000
        guard OpusRealtimeEncoder.isSupported(sampleRate: resolvedSampleRate) else {
            throw OpusRealtimeError.unsupportedSampleRate(resolvedSampleRate)
        }

        guard let decoder = OpusPacketDecoder(sampleRate: resolvedSampleRate) else {
            throw OpusRealtimeError.failedToCreateDecoder
        }

        do {
            pcmConverter = try PCM16MonoAudioBufferConverter(sampleRate: resolvedSampleRate)
        } catch {
            throw OpusRealtimeEncoder.mapPCMError(error)
        }

        self.sampleRate = resolvedSampleRate
        self.decoder = decoder
    }

    public func decode(packet: Data, decodeFEC: Bool = false) throws -> AVAudioPCMBuffer {
        guard let pcmData = decoder.decodePacket(packet, frameSize: 0, decodeFEC: decodeFEC) else {
            throw OpusRealtimeError.failedToDecodePacket
        }

        do {
            return try pcmConverter.makeBuffer(fromPCMData: pcmData)
        } catch {
            throw OpusRealtimeEncoder.mapPCMError(error)
        }
    }

    public func decodeMissingPacket(
        frameDurationMs: Int = 20,
        decodeFEC: Bool = false
    ) throws -> AVAudioPCMBuffer {
        let frameSize = try Self.frameSize(sampleRate: sampleRate, frameDurationMs: frameDurationMs)
        guard let pcmData = decoder.decodePacket(nil, frameSize: frameSize, decodeFEC: decodeFEC) else {
            throw OpusRealtimeError.failedToDecodePacket
        }

        do {
            return try pcmConverter.makeBuffer(fromPCMData: pcmData)
        } catch {
            throw OpusRealtimeEncoder.mapPCMError(error)
        }
    }

    public func reset() {
        decoder.resetState()
    }

    private static func frameSize(sampleRate: Int, frameDurationMs: Int) throws -> Int {
        let validDurations = [5, 10, 20, 40, 60]
        guard validDurations.contains(frameDurationMs) else {
            throw OpusRealtimeError.invalidFrameDuration(frameDurationMs)
        }

        return sampleRate * frameDurationMs / 1_000
    }
}
