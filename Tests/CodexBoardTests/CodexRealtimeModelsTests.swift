import Foundation
import XCTest
@testable import CodexBoard

final class CodexRealtimeModelsTests: XCTestCase {
    func testDraftDecoderAcceptsOnlyFrozenProjectAndKnownFields() throws {
        let call = CodexDynamicToolCall(
            threadID: "thread-live",
            turnID: "turn-live",
            callID: "call-1",
            namespace: nil,
            tool: LiveTaskDraftDecoder.toolName,
            arguments: .object([
                "projectRef": .string("project-session-ref"),
                "tasks": .array([
                    .object([
                        "title": .string("  修复登录流程  "),
                        "sourceKind": .string(TaskSourceKind.issue.rawValue),
                        "sourceText": .string("  登录后页面没有跳转。  ")
                    ])
                ])
            ])
        )

        let drafts = try LiveTaskDraftDecoder.decode(
            call: call,
            projectReference: "project-session-ref",
            projectID: "local:/workspace/project"
        )

        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].projectID, "local:/workspace/project")
        XCTAssertEqual(drafts[0].title, "修复登录流程")
        XCTAssertEqual(drafts[0].sourceKind, .issue)
        XCTAssertEqual(drafts[0].sourceText, "登录后页面没有跳转。")
        XCTAssertEqual(drafts[0].callID, "call-1")
    }

    func testDraftDecoderRejectsModelSuppliedProjectAndExtraFields() {
        for arguments in [
            JSONValue.object([
                "projectRef": .string("another-project"),
                "tasks": .array([validTaskArguments])
            ]),
            JSONValue.object([
                "projectRef": .string("project-session-ref"),
                "tasks": .array([
                    .object([
                        "title": .string("标题"),
                        "sourceKind": .string(TaskSourceKind.issue.rawValue),
                        "sourceText": .string("内容"),
                        "path": .string("/tmp/escape")
                    ])
                ])
            ])
        ] {
            let call = CodexDynamicToolCall(
                threadID: "thread-live",
                turnID: "turn-live",
                callID: UUID().uuidString,
                namespace: nil,
                tool: LiveTaskDraftDecoder.toolName,
                arguments: arguments
            )
            XCTAssertThrowsError(try LiveTaskDraftDecoder.decode(
                call: call,
                projectReference: "project-session-ref",
                projectID: "trusted-project"
            ))
        }
    }

    func testWireCodecEncodesAndDecodesPCM16AtRealtimeSampleRate() throws {
        let inputSamples: [Float] = [-1, 0, 1]
        let input = try RealtimeAudioBuffer(
            data: inputSamples.withUnsafeBufferPointer { Data(buffer: $0) },
            sampleRate: 24_000,
            channelCount: 1
        )

        let wire = try RealtimeAudioWireCodec.encodeCapture(input)
        let output = try RealtimeAudioWireCodec.decodePlayback(wire)

        XCTAssertEqual(wire.sampleRate, 24_000)
        XCTAssertEqual(wire.channelCount, 1)
        XCTAssertEqual(wire.samplesPerChannel, 3)
        XCTAssertEqual(output.frameCount, 3)
        let decoded = decodeFloat32(output.data)
        XCTAssertEqual(decoded[0], -32_767 / 32_768, accuracy: 0.000_01)
        XCTAssertEqual(decoded[1], 0, accuracy: 0.000_01)
        XCTAssertEqual(decoded[2], 32_767 / 32_768, accuracy: 0.000_01)
    }

    func testWireCodecResamplesAndCreatesBoundedSilenceTail() throws {
        let samples = [Float](repeating: 0.25, count: 480)
        let input = try RealtimeAudioBuffer(
            data: samples.withUnsafeBufferPointer { Data(buffer: $0) },
            sampleRate: 48_000,
            channelCount: 1
        )

        let resampled = try RealtimeAudioWireCodec.encodeCapture(input)
        let silence = try RealtimeAudioWireCodec.silence(milliseconds: 400)

        XCTAssertEqual(resampled.samplesPerChannel, 240)
        XCTAssertEqual(resampled.data.count, 240 * MemoryLayout<Int16>.size)
        XCTAssertEqual(silence.samplesPerChannel, 9_600)
        XCTAssertEqual(silence.data.count, 9_600 * MemoryLayout<Int16>.size)
        XCTAssertTrue(silence.data.allSatisfy { $0 == 0 })
    }

    private var validTaskArguments: JSONValue {
        .object([
            "title": .string("标题"),
            "sourceKind": .string(TaskSourceKind.issue.rawValue),
            "sourceText": .string("内容")
        ])
    }

    private func decodeFloat32(_ data: Data) -> [Float] {
        data.withUnsafeBytes { bytes in
            (0..<(data.count / MemoryLayout<Float>.size)).map { index in
                let stored = bytes.loadUnaligned(
                    fromByteOffset: index * MemoryLayout<Float>.size,
                    as: UInt32.self
                )
                return Float(bitPattern: UInt32(littleEndian: stored))
            }
        }
    }
}
