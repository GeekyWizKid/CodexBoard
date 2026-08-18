@preconcurrency import AVFoundation
import Foundation

enum RealtimeAudioEncoding: String, Equatable, Sendable {
    case float32Interleaved
}

/// Canonical audio exchanged with the realtime transport.
///
/// `data` is interleaved, little-endian IEEE 754 Float32 PCM. Capture always
/// produces one channel. Playback accepts one or more channels and converts the
/// supplied sample rate and channel layout to the current output device.
struct RealtimeAudioBuffer: Equatable, Sendable {
    static let bytesPerSample = MemoryLayout<Float>.size

    let data: Data
    let sampleRate: Double
    let channelCount: UInt32
    let frameCount: UInt32
    let encoding: RealtimeAudioEncoding

    init(
        data: Data,
        sampleRate: Double,
        channelCount: UInt32,
        frameCount: UInt32,
        encoding: RealtimeAudioEncoding = .float32Interleaved
    ) throws {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw RealtimeAudioServiceError.invalidSampleRate
        }
        guard channelCount > 0 else {
            throw RealtimeAudioServiceError.invalidChannelCount
        }
        guard frameCount > 0 else {
            throw RealtimeAudioServiceError.emptyAudioChunk
        }

        let (sampleCount, sampleCountOverflow) = Int(frameCount)
            .multipliedReportingOverflow(by: Int(channelCount))
        let (expectedByteCount, byteCountOverflow) = sampleCount
            .multipliedReportingOverflow(by: Self.bytesPerSample)
        guard !sampleCountOverflow,
              !byteCountOverflow,
              data.count == expectedByteCount
        else {
            throw RealtimeAudioServiceError.invalidPCMByteCount(
                expected: byteCountOverflow ? nil : expectedByteCount,
                actual: data.count
            )
        }

        self.data = data
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameCount = frameCount
        self.encoding = encoding
    }

    init(
        data: Data,
        sampleRate: Double,
        channelCount: UInt32,
        encoding: RealtimeAudioEncoding = .float32Interleaved
    ) throws {
        guard channelCount > 0 else {
            throw RealtimeAudioServiceError.invalidChannelCount
        }
        let bytesPerFrame = Int(channelCount) * Self.bytesPerSample
        guard !data.isEmpty, data.count.isMultiple(of: bytesPerFrame) else {
            throw RealtimeAudioServiceError.invalidPCMByteCount(expected: nil, actual: data.count)
        }
        let frames = data.count / bytesPerFrame
        guard let frameCount = UInt32(exactly: frames) else {
            throw RealtimeAudioServiceError.audioChunkTooLarge
        }
        try self.init(
            data: data,
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameCount: frameCount,
            encoding: encoding
        )
    }
}

enum RealtimeAudioPermission: String, Equatable, Sendable {
    case notDetermined
    case restricted
    case denied
    case authorized
}

enum RealtimeAudioServiceError: Error, Equatable, LocalizedError, Sendable {
    case microphonePermissionNotRequested
    case microphonePermissionDenied
    case captureAlreadyRunning
    case captureStartCancelled
    case invalidSampleRate
    case invalidChannelCount
    case emptyAudioChunk
    case invalidPCMByteCount(expected: Int?, actual: Int)
    case audioChunkTooLarge
    case inputUnavailable
    case outputUnavailable
    case unsupportedPCMFormat
    case engineStartFailed(String)
    case audioConversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionNotRequested:
            "尚未请求麦克风权限。"
        case .microphonePermissionDenied:
            "麦克风权限不可用，请在系统设置中允许 CodexBoard 使用麦克风。"
        case .captureAlreadyRunning:
            "麦克风采集已经在运行。"
        case .captureStartCancelled:
            "麦克风采集在启动完成前被停止。"
        case .invalidSampleRate:
            "音频采样率无效。"
        case .invalidChannelCount:
            "音频声道数无效。"
        case .emptyAudioChunk:
            "音频块不能为空。"
        case let .invalidPCMByteCount(expected, actual):
            if let expected {
                "Float32 PCM 数据长度无效：预期 \(expected) 字节，实际 \(actual) 字节。"
            } else {
                "Float32 PCM 数据长度无效：实际 \(actual) 字节。"
            }
        case .audioChunkTooLarge:
            "音频块超过可处理的帧数。"
        case .inputUnavailable:
            "没有可用的音频输入设备。"
        case .outputUnavailable:
            "没有可用的音频输出设备。"
        case .unsupportedPCMFormat:
            "音频设备没有提供可用的 Float32 PCM 格式。"
        case let .engineStartFailed(message):
            "音频引擎启动失败：\(message)"
        case let .audioConversionFailed(message):
            "音频格式转换失败：\(message)"
        }
    }
}

/// Injectable boundary used to exercise the service without touching audio
/// hardware. Implementations must serialize their own mutable device state.
protocol RealtimeAudioBackend: Sendable {
    func permissionStatus() async -> RealtimeAudioPermission
    func requestPermission() async -> RealtimeAudioPermission
    func startCapture(
        onChunk: @escaping @Sendable (RealtimeAudioBuffer) -> Void
    ) async throws
    func stopCapture() async
    func enqueuePlayback(_ chunk: RealtimeAudioBuffer) async throws
    func stopPlayback() async
    func waitUntilPlaybackCompletes() async
}

/// Actor-owned facade for realtime microphone capture and audio playback.
///
/// This actor is deliberately not isolated to `MainActor`. The production
/// backend additionally confines all `AVAudioEngine` graph mutations to its own
/// serial queue, while capture delivery is moved off the realtime render thread.
actor RealtimeAudioService {
    typealias ChunkHandler = @Sendable (RealtimeAudioBuffer) -> Void

    private let backend: any RealtimeAudioBackend
    private var captureGate: RealtimeAudioCaptureGate?

    private(set) var isCapturing = false

    init(backend: any RealtimeAudioBackend = AVAudioEngineRealtimeAudioBackend()) {
        self.backend = backend
    }

    func permissionStatus() async -> RealtimeAudioPermission {
        await backend.permissionStatus()
    }

    @discardableResult
    func requestPermission() async -> RealtimeAudioPermission {
        await backend.requestPermission()
    }

    func startCapture(onChunk: @escaping ChunkHandler) async throws {
        guard captureGate == nil else {
            throw RealtimeAudioServiceError.captureAlreadyRunning
        }

        switch await backend.permissionStatus() {
        case .authorized:
            break
        case .notDetermined:
            throw RealtimeAudioServiceError.microphonePermissionNotRequested
        case .restricted, .denied:
            throw RealtimeAudioServiceError.microphonePermissionDenied
        }

        let gate = RealtimeAudioCaptureGate(handler: onChunk)
        captureGate = gate

        do {
            try await backend.startCapture { chunk in
                gate.deliver(chunk)
            }
            guard captureGate === gate else {
                gate.invalidate()
                await backend.stopCapture()
                throw RealtimeAudioServiceError.captureStartCancelled
            }
            isCapturing = true
        } catch {
            gate.invalidate()
            if captureGate === gate {
                captureGate = nil
                isCapturing = false
            }
            throw error
        }
    }

    func stopCapture() async {
        let gate = captureGate
        captureGate = nil
        gate?.invalidate()
        isCapturing = false
        await backend.stopCapture()
    }

    func play(_ chunk: RealtimeAudioBuffer) async throws {
        try await backend.enqueuePlayback(chunk)
    }

    func waitUntilPlaybackCompletes() async {
        await backend.waitUntilPlaybackCompletes()
    }

    func stopPlayback() async {
        await backend.stopPlayback()
    }

    func stop() async {
        let gate = captureGate
        captureGate = nil
        gate?.invalidate()
        isCapturing = false
        await backend.stopCapture()
        await backend.stopPlayback()
    }
}

final class AVAudioEngineRealtimeAudioBackend: RealtimeAudioBackend, @unchecked Sendable {
    private let engine: AVAudioEngine
    private let playerNode: AVAudioPlayerNode
    private let audioQueue: DispatchQueue
    private let captureDeliveryQueue: DispatchQueue

    // Accessed only on audioQueue.
    private var captureTapInstalled = false
    private var playerAttached = false
    private var playbackFormat: AVAudioFormat?
    private var playbackGeneration: UInt64 = 0
    private var pendingPlaybackBuffers = 0
    private var playbackWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        engine: AVAudioEngine = AVAudioEngine(),
        playerNode: AVAudioPlayerNode = AVAudioPlayerNode(),
        queueLabel: String = "com.local.CodexBoard.realtime-audio"
    ) {
        self.engine = engine
        self.playerNode = playerNode
        audioQueue = DispatchQueue(label: "\(queueLabel).engine", qos: .userInitiated)
        captureDeliveryQueue = DispatchQueue(label: "\(queueLabel).capture", qos: .userInitiated)
    }

    deinit {
        if captureTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
        }
        playerNode.stop()
        engine.stop()
        playbackWaiters.forEach { $0.resume() }
    }

    func permissionStatus() async -> RealtimeAudioPermission {
        Self.currentPermissionStatus()
    }

    func requestPermission() async -> RealtimeAudioPermission {
        let current = Self.currentPermissionStatus()
        guard current == .notDetermined else { return current }

        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                continuation.resume(returning: Self.currentPermissionStatus())
            }
        }
    }

    func startCapture(
        onChunk: @escaping @Sendable (RealtimeAudioBuffer) -> Void
    ) async throws {
        guard Self.currentPermissionStatus() == .authorized else {
            throw RealtimeAudioServiceError.microphonePermissionDenied
        }

        try await performOnAudioQueue {
            guard !self.captureTapInstalled else {
                throw RealtimeAudioServiceError.captureAlreadyRunning
            }

            let inputNode = self.engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw RealtimeAudioServiceError.inputUnavailable
            }
            guard inputFormat.commonFormat == .pcmFormatFloat32 else {
                throw RealtimeAudioServiceError.unsupportedPCMFormat
            }

            let deliveryQueue = self.captureDeliveryQueue
            inputNode.installTap(
                onBus: 0,
                bufferSize: 1_024,
                format: inputFormat
            ) { buffer, _ in
                guard let chunk = try? RealtimeAudioPCMCodec.makeMonoChunk(from: buffer) else {
                    return
                }
                deliveryQueue.async {
                    onChunk(chunk)
                }
            }
            self.captureTapInstalled = true

            do {
                try self.ensureEngineRunning()
            } catch {
                inputNode.removeTap(onBus: 0)
                self.captureTapInstalled = false
                throw error
            }
        }
    }

    func stopCapture() async {
        await performOnAudioQueue {
            guard self.captureTapInstalled else { return }
            self.engine.inputNode.removeTap(onBus: 0)
            self.captureTapInstalled = false
            if self.pendingPlaybackBuffers == 0 {
                self.playerNode.stop()
                self.engine.stop()
            }
        }
    }

    func enqueuePlayback(_ chunk: RealtimeAudioBuffer) async throws {
        try await performOnAudioQueue {
            let targetFormat = try self.ensurePlayerConfigured()
            let sourceBuffer = try RealtimeAudioPCMCodec.makePCMBuffer(from: chunk)
            let playbackBuffer = try RealtimeAudioPCMCodec.convert(
                sourceBuffer,
                to: targetFormat
            )
            try self.ensureEngineRunning()

            let generation = self.playbackGeneration
            self.pendingPlaybackBuffers += 1
            self.playerNode.scheduleBuffer(
                playbackBuffer,
                completionCallbackType: .dataPlayedBack
            ) { [weak self] _ in
                guard let self else { return }
                self.audioQueue.async {
                    self.completePlaybackBuffer(generation: generation)
                }
            }
            if !self.playerNode.isPlaying {
                self.playerNode.play()
            }
        }
    }

    func stopPlayback() async {
        await performOnAudioQueue {
            self.playbackGeneration &+= 1
            self.playerNode.stop()
            self.pendingPlaybackBuffers = 0
            self.resumePlaybackWaiters()
            if !self.captureTapInstalled {
                self.engine.stop()
            }
        }
    }

    func waitUntilPlaybackCompletes() async {
        await withCheckedContinuation { continuation in
            audioQueue.async {
                if self.pendingPlaybackBuffers == 0 {
                    continuation.resume()
                } else {
                    self.playbackWaiters.append(continuation)
                }
            }
        }
    }

    private static func currentPermissionStatus() -> RealtimeAudioPermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            .notDetermined
        case .restricted:
            .restricted
        case .denied:
            .denied
        case .authorized:
            .authorized
        @unknown default:
            .denied
        }
    }

    private func ensurePlayerConfigured() throws -> AVAudioFormat {
        if let playbackFormat { return playbackFormat }

        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0,
              format.channelCount > 0,
              format.commonFormat == .pcmFormatFloat32
        else {
            throw RealtimeAudioServiceError.outputUnavailable
        }

        if !playerAttached {
            engine.attach(playerNode)
            playerAttached = true
        }
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        playbackFormat = format
        return format
    }

    private func ensureEngineRunning() throws {
        guard !engine.isRunning else { return }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw RealtimeAudioServiceError.engineStartFailed(error.localizedDescription)
        }
    }

    private func completePlaybackBuffer(generation: UInt64) {
        guard generation == playbackGeneration, pendingPlaybackBuffers > 0 else { return }
        pendingPlaybackBuffers -= 1
        if pendingPlaybackBuffers == 0 {
            playerNode.stop()
            resumePlaybackWaiters()
            if !captureTapInstalled {
                engine.stop()
            }
        }
    }

    private func resumePlaybackWaiters() {
        let waiters = playbackWaiters
        playbackWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func performOnAudioQueue<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            audioQueue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func performOnAudioQueue(
        _ operation: @escaping @Sendable () -> Void
    ) async {
        await withCheckedContinuation { continuation in
            audioQueue.async {
                operation()
                continuation.resume()
            }
        }
    }
}

enum RealtimeAudioPCMCodec {
    static func makeMonoChunk(from buffer: AVAudioPCMBuffer) throws -> RealtimeAudioBuffer {
        let format = buffer.format
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        guard frameCount > 0 else {
            throw RealtimeAudioServiceError.emptyAudioChunk
        }
        guard format.sampleRate > 0, format.sampleRate.isFinite else {
            throw RealtimeAudioServiceError.invalidSampleRate
        }
        guard channelCount > 0 else {
            throw RealtimeAudioServiceError.invalidChannelCount
        }
        guard format.commonFormat == .pcmFormatFloat32 else {
            throw RealtimeAudioServiceError.unsupportedPCMFormat
        }

        var monoSamples = [Float](repeating: 0, count: frameCount)
        if format.isInterleaved {
            let audioBuffer = buffer.audioBufferList.pointee.mBuffers
            guard let rawSamples = audioBuffer.mData?.assumingMemoryBound(to: Float.self) else {
                throw RealtimeAudioServiceError.unsupportedPCMFormat
            }
            for frame in 0..<frameCount {
                var total: Float = 0
                let frameOffset = frame * channelCount
                for channel in 0..<channelCount {
                    total += rawSamples[frameOffset + channel]
                }
                monoSamples[frame] = total / Float(channelCount)
            }
        } else {
            guard let channels = buffer.floatChannelData else {
                throw RealtimeAudioServiceError.unsupportedPCMFormat
            }
            for frame in 0..<frameCount {
                var total: Float = 0
                for channel in 0..<channelCount {
                    total += channels[channel][frame]
                }
                monoSamples[frame] = total / Float(channelCount)
            }
        }

        let data = monoSamples.withUnsafeBufferPointer { Data(buffer: $0) }
        return try RealtimeAudioBuffer(
            data: data,
            sampleRate: format.sampleRate,
            channelCount: 1,
            frameCount: UInt32(frameCount)
        )
    }

    static func makePCMBuffer(from chunk: RealtimeAudioBuffer) throws -> AVAudioPCMBuffer {
        guard chunk.encoding == .float32Interleaved else {
            throw RealtimeAudioServiceError.unsupportedPCMFormat
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: chunk.sampleRate,
            channels: AVAudioChannelCount(chunk.channelCount),
            interleaved: false
        ),
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(chunk.frameCount)
        ),
        let channels = buffer.floatChannelData
        else {
            throw RealtimeAudioServiceError.unsupportedPCMFormat
        }

        let channelCount = Int(chunk.channelCount)
        let frameCount = Int(chunk.frameCount)
        chunk.data.withUnsafeBytes { bytes in
            for frame in 0..<frameCount {
                for channel in 0..<channelCount {
                    let sampleIndex = frame * channelCount + channel
                    let storedBits = bytes.loadUnaligned(
                        fromByteOffset: sampleIndex * RealtimeAudioBuffer.bytesPerSample,
                        as: UInt32.self
                    )
                    channels[channel][frame] = Float(
                        bitPattern: UInt32(littleEndian: storedBits)
                    )
                }
            }
        }
        buffer.frameLength = AVAudioFrameCount(chunk.frameCount)
        return buffer
    }

    static func convert(
        _ source: AVAudioPCMBuffer,
        to targetFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        if formatsMatch(source.format, targetFormat) {
            return source
        }
        guard let converter = AVAudioConverter(from: source.format, to: targetFormat) else {
            throw RealtimeAudioServiceError.audioConversionFailed("无法创建 AVAudioConverter。")
        }

        let rateRatio = targetFormat.sampleRate / source.format.sampleRate
        let estimatedFrameCount = ceil(Double(source.frameLength) * rateRatio) + 32
        guard estimatedFrameCount.isFinite,
              estimatedFrameCount > 0,
              estimatedFrameCount <= Double(UInt32.max),
              let output = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: AVAudioFrameCount(estimatedFrameCount)
              )
        else {
            throw RealtimeAudioServiceError.audioChunkTooLarge
        }

        let inputState = RealtimeAudioConverterInputState()
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard inputState.takeInput() else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            inputStatus.pointee = .haveData
            return source
        }

        if let conversionError {
            throw RealtimeAudioServiceError.audioConversionFailed(
                conversionError.localizedDescription
            )
        }
        guard status != .error, output.frameLength > 0 else {
            throw RealtimeAudioServiceError.audioConversionFailed(
                "转换器没有生成可播放的 PCM 帧。"
            )
        }
        return output
    }

    private static func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.commonFormat == rhs.commonFormat
            && lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.isInterleaved == rhs.isInterleaved
    }
}

private final class RealtimeAudioCaptureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: RealtimeAudioService.ChunkHandler?

    init(handler: @escaping RealtimeAudioService.ChunkHandler) {
        self.handler = handler
    }

    func deliver(_ chunk: RealtimeAudioBuffer) {
        lock.lock()
        defer { lock.unlock() }
        handler?(chunk)
    }

    func invalidate() {
        lock.lock()
        handler = nil
        lock.unlock()
    }
}

private final class RealtimeAudioConverterInputState: @unchecked Sendable {
    private let lock = NSLock()
    private var suppliedInput = false

    func takeInput() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !suppliedInput else { return false }
        suppliedInput = true
        return true
    }
}
