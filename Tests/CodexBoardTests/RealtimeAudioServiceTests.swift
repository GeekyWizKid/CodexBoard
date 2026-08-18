import AVFoundation
import Foundation
import XCTest
@testable import CodexBoard

final class RealtimeAudioServiceTests: XCTestCase {
    func testBufferRejectsMismatchedFloat32PCMShape() throws {
        XCTAssertThrowsError(
            try RealtimeAudioBuffer(
                data: Data(count: 4),
                sampleRate: 24_000,
                channelCount: 1,
                frameCount: 2
            )
        ) { error in
            XCTAssertEqual(
                error as? RealtimeAudioServiceError,
                .invalidPCMByteCount(expected: 8, actual: 4)
            )
        }
    }

    func testCodecDownmixesNonInterleavedFloat32ToMono() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
        let channels = try XCTUnwrap(buffer.floatChannelData)
        channels[0][0] = 1
        channels[0][1] = 0.5
        channels[0][2] = -1
        channels[1][0] = -1
        channels[1][1] = 0.5
        channels[1][2] = 0
        buffer.frameLength = 3

        let chunk = try RealtimeAudioPCMCodec.makeMonoChunk(from: buffer)

        XCTAssertEqual(chunk.sampleRate, 48_000)
        XCTAssertEqual(chunk.channelCount, 1)
        XCTAssertEqual(chunk.frameCount, 3)
        XCTAssertEqual(chunk.encoding, .float32Interleaved)
        XCTAssertEqual(decodedSamples(from: chunk), [0, 0.5, -0.5])
    }

    func testCodecRestoresInterleavedChannelsForPlayback() throws {
        let chunk = try makeBuffer(
            samples: [1, -1, 0.25, -0.25],
            sampleRate: 24_000,
            channelCount: 2
        )

        let buffer = try RealtimeAudioPCMCodec.makePCMBuffer(from: chunk)
        let channels = try XCTUnwrap(buffer.floatChannelData)

        XCTAssertEqual(buffer.frameLength, 2)
        XCTAssertEqual(channels[0][0], 1)
        XCTAssertEqual(channels[1][0], -1)
        XCTAssertEqual(channels[0][1], 0.25)
        XCTAssertEqual(channels[1][1], -0.25)
    }

    func testServiceDeliversCaptureAndDropsStaleChunksAfterStop() async throws {
        let backend = FakeRealtimeAudioBackend(permission: .authorized)
        let service = RealtimeAudioService(backend: backend)
        let recorder = AudioBufferRecorder()
        let chunk = try makeBuffer(samples: [0.1, -0.1], sampleRate: 24_000)

        try await service.startCapture { buffer in
            recorder.append(buffer)
        }
        await backend.emit(chunk)
        try await waitForRecordedBufferCount(1, recorder: recorder)

        await service.stopCapture()
        await backend.emitStale(chunk)
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(recorder.buffers, [chunk])
        let isCapturing = await service.isCapturing
        XCTAssertFalse(isCapturing)
        let snapshot = await backend.snapshot()
        XCTAssertEqual(snapshot.captureStarts, 1)
        XCTAssertEqual(snapshot.captureStops, 1)
    }

    func testServiceDoesNotStartCaptureWithoutPermission() async throws {
        let backend = FakeRealtimeAudioBackend(permission: .denied)
        let service = RealtimeAudioService(backend: backend)

        do {
            try await service.startCapture { _ in }
            XCTFail("Expected microphone permission failure")
        } catch {
            XCTAssertEqual(
                error as? RealtimeAudioServiceError,
                .microphonePermissionDenied
            )
        }

        let snapshot = await backend.snapshot()
        XCTAssertEqual(snapshot.captureStarts, 0)
    }

    func testServiceForwardsPlaybackInOrderAndWaitsForDrain() async throws {
        let backend = FakeRealtimeAudioBackend(permission: .authorized)
        let service = RealtimeAudioService(backend: backend)
        let first = try makeBuffer(samples: [0.1], sampleRate: 24_000)
        let second = try makeBuffer(samples: [0.2], sampleRate: 24_000)

        try await service.play(first)
        try await service.play(second)
        await service.waitUntilPlaybackCompletes()

        let snapshot = await backend.snapshot()
        XCTAssertEqual(snapshot.playedBuffers, [first, second])
        XCTAssertEqual(snapshot.playbackWaits, 1)
    }

    private func makeBuffer(
        samples: [Float],
        sampleRate: Double,
        channelCount: UInt32 = 1
    ) throws -> RealtimeAudioBuffer {
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        return try RealtimeAudioBuffer(
            data: data,
            sampleRate: sampleRate,
            channelCount: channelCount
        )
    }

    private func decodedSamples(from chunk: RealtimeAudioBuffer) -> [Float] {
        chunk.data.withUnsafeBytes { bytes in
            (0..<(chunk.data.count / RealtimeAudioBuffer.bytesPerSample)).map { index in
                let storedBits = bytes.loadUnaligned(
                    fromByteOffset: index * RealtimeAudioBuffer.bytesPerSample,
                    as: UInt32.self
                )
                return Float(bitPattern: UInt32(littleEndian: storedBits))
            }
        }
    }

    private func waitForRecordedBufferCount(
        _ count: Int,
        recorder: AudioBufferRecorder
    ) async throws {
        for _ in 0..<50 {
            if recorder.buffers.count == count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for \(count) captured audio buffers")
    }
}

private final class AudioBufferRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RealtimeAudioBuffer] = []

    var buffers: [RealtimeAudioBuffer] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ buffer: RealtimeAudioBuffer) {
        lock.lock()
        storage.append(buffer)
        lock.unlock()
    }
}

private actor FakeRealtimeAudioBackend: RealtimeAudioBackend {
    struct Snapshot: Sendable {
        let captureStarts: Int
        let captureStops: Int
        let playedBuffers: [RealtimeAudioBuffer]
        let playbackWaits: Int
    }

    private var permission: RealtimeAudioPermission
    private var captureHandler: (@Sendable (RealtimeAudioBuffer) -> Void)?
    private var staleCaptureHandler: (@Sendable (RealtimeAudioBuffer) -> Void)?
    private var captureStarts = 0
    private var captureStops = 0
    private var playedBuffers: [RealtimeAudioBuffer] = []
    private var playbackWaits = 0

    init(permission: RealtimeAudioPermission) {
        self.permission = permission
    }

    func permissionStatus() async -> RealtimeAudioPermission {
        permission
    }

    func requestPermission() async -> RealtimeAudioPermission {
        permission
    }

    func startCapture(
        onChunk: @escaping @Sendable (RealtimeAudioBuffer) -> Void
    ) async throws {
        captureStarts += 1
        captureHandler = onChunk
        staleCaptureHandler = onChunk
    }

    func stopCapture() async {
        captureStops += 1
        captureHandler = nil
    }

    func enqueuePlayback(_ chunk: RealtimeAudioBuffer) async throws {
        playedBuffers.append(chunk)
    }

    func stopPlayback() async {}

    func waitUntilPlaybackCompletes() async {
        playbackWaits += 1
    }

    func emit(_ chunk: RealtimeAudioBuffer) {
        captureHandler?(chunk)
    }

    func emitStale(_ chunk: RealtimeAudioBuffer) {
        staleCaptureHandler?(chunk)
    }

    func snapshot() -> Snapshot {
        Snapshot(
            captureStarts: captureStarts,
            captureStops: captureStops,
            playedBuffers: playedBuffers,
            playbackWaits: playbackWaits
        )
    }
}
