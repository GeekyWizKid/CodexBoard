import Foundation

enum CodexRealtimeVersion: String, Equatable, Sendable {
    case v1
    case v2
    case v3
}

enum CodexRealtimeOutputModality: String, Equatable, Sendable {
    case text
    case audio
}

enum CodexRealtimeTextRole: String, Equatable, Sendable {
    case user
    case developer
    case assistant
}

struct CodexRealtimeStartOptions: Equatable, Sendable {
    var outputModality: CodexRealtimeOutputModality = .audio
    var model = "gpt-realtime-2.1"
    var voice: String? = "marin"
    var version: CodexRealtimeVersion = .v2
    var prompt: String?
    var includeStartupContext = false
}

/// Realtime's `audio/pcm` payload: signed 16-bit little-endian PCM.
struct CodexRealtimeAudioChunk: Equatable, Sendable {
    let data: Data
    let sampleRate: UInt32
    let channelCount: UInt16
    let samplesPerChannel: UInt32?
    let itemID: String?

    init(
        data: Data,
        sampleRate: UInt32,
        channelCount: UInt16,
        samplesPerChannel: UInt32? = nil,
        itemID: String? = nil
    ) throws {
        guard sampleRate > 0 else { throw CodexRealtimeError.invalidAudioChunk }
        guard channelCount > 0 else { throw CodexRealtimeError.invalidAudioChunk }
        let bytesPerFrame = Int(channelCount) * MemoryLayout<Int16>.size
        guard !data.isEmpty, data.count.isMultiple(of: bytesPerFrame) else {
            throw CodexRealtimeError.invalidAudioChunk
        }
        if let samplesPerChannel,
           Int(samplesPerChannel) != data.count / bytesPerFrame {
            throw CodexRealtimeError.invalidAudioChunk
        }
        self.data = data
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.samplesPerChannel = samplesPerChannel
        self.itemID = itemID
    }
}

struct CodexRealtimeVoiceCatalog: Equatable, Sendable {
    let v1: [String]
    let v2: [String]
    let defaultV1: String
    let defaultV2: String
}

struct CodexDynamicToolSpec: Equatable, Sendable {
    let name: String
    let description: String
    let inputSchema: JSONValue
    var deferLoading = false
}

struct CodexDynamicToolCall: Equatable, Sendable {
    let threadID: String
    let turnID: String
    let callID: String
    let namespace: String?
    let tool: String
    let arguments: JSONValue
}

enum CodexDynamicToolContentItem: Equatable, Sendable {
    case text(String)

    var jsonValue: JSONValue {
        switch self {
        case let .text(text):
            .object([
                "type": .string("inputText"),
                "text": .string(text)
            ])
        }
    }
}

struct CodexDynamicToolResult: Equatable, Sendable {
    let success: Bool
    let contentItems: [CodexDynamicToolContentItem]

    var jsonValue: JSONValue {
        .object([
            "success": .bool(success),
            "contentItems": .array(contentItems.map(\.jsonValue))
        ])
    }
}

enum CodexRealtimeEvent: Equatable, Sendable {
    case started(threadID: String, version: CodexRealtimeVersion, sessionID: String?)
    case itemAdded(threadID: String, item: JSONValue)
    case transcriptDelta(threadID: String, role: String, delta: String)
    case transcriptDone(threadID: String, role: String, text: String)
    case outputAudioDelta(threadID: String, chunk: CodexRealtimeAudioChunk)
    case sdp(threadID: String, sdp: String)
    case error(threadID: String, message: String)
    case closed(threadID: String, reason: String?)
    case connectionLost(message: String)
}

enum CodexRealtimeError: LocalizedError, Equatable {
    case invalidAudioChunk
    case invalidVoiceCatalog
    case invalidNotification(String)
    case unsupportedDynamicTool(String)

    var errorDescription: String? {
        switch self {
        case .invalidAudioChunk:
            "Realtime 返回了无效的 PCM 音频块。"
        case .invalidVoiceCatalog:
            "Realtime 没有返回有效的声音列表。"
        case let .invalidNotification(method):
            "Realtime 事件格式无效：\(method)"
        case let .unsupportedDynamicTool(tool):
            "Live 会话请求了未注册的工具：\(tool)"
        }
    }
}

struct LiveTranscriptEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let role: String
    let text: String

    init(id: UUID = UUID(), role: String, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

struct LiveTaskDraft: Identifiable, Equatable, Sendable {
    let id: UUID
    let threadID: String
    let callID: String
    let projectID: String
    var title: String
    var sourceKind: TaskSourceKind
    var sourceText: String

    init(
        id: UUID = UUID(),
        threadID: String,
        callID: String,
        projectID: String,
        title: String,
        sourceKind: TaskSourceKind,
        sourceText: String
    ) {
        self.id = id
        self.threadID = threadID
        self.callID = callID
        self.projectID = projectID
        self.title = title
        self.sourceKind = sourceKind
        self.sourceText = sourceText
    }
}

enum LiveTaskDraftDecoder {
    static let toolName = "submit_task_drafts"

    static func toolSpec(projectReference: String) -> CodexDynamicToolSpec {
        CodexDynamicToolSpec(
            name: toolName,
            description: "提交 1 到 5 个 CodexBoard 任务草稿供用户预览。只能在需求已经明确或用户要求生成草稿时调用；调用不会创建或执行任务。",
            inputSchema: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([
                    "projectRef": .object([
                        "type": .string("string"),
                        "const": .string(projectReference)
                    ]),
                    "tasks": .object([
                        "type": .string("array"),
                        "minItems": .integer(1),
                        "maxItems": .integer(5),
                        "items": .object([
                            "type": .string("object"),
                            "additionalProperties": .bool(false),
                            "properties": .object([
                                "title": .object([
                                    "type": .string("string"),
                                    "minLength": .integer(1),
                                    "maxLength": .integer(80)
                                ]),
                                "sourceKind": .object([
                                    "type": .string("string"),
                                    "enum": .array([
                                        .string(TaskSourceKind.issue.rawValue),
                                        .string(TaskSourceKind.developmentPlan.rawValue)
                                    ])
                                ]),
                                "sourceText": .object([
                                    "type": .string("string"),
                                    "minLength": .integer(1),
                                    "maxLength": .integer(20_000)
                                ])
                            ]),
                            "required": .array([
                                .string("title"),
                                .string("sourceKind"),
                                .string("sourceText")
                            ])
                        ])
                    ])
                ]),
                "required": .array([.string("projectRef"), .string("tasks")])
            ])
        )
    }

    static func decode(
        call: CodexDynamicToolCall,
        projectReference: String,
        projectID: String
    ) throws -> [LiveTaskDraft] {
        guard call.tool == toolName,
              call.arguments["projectRef"]?.stringValue == projectReference,
              let values = call.arguments["tasks"]?.arrayValue,
              (1...5).contains(values.count)
        else {
            throw CodexRealtimeError.invalidNotification("item/tool/call")
        }

        return try values.map { value in
            guard let object = value.objectValue,
                  Set(object.keys).isSubset(of: ["title", "sourceKind", "sourceText"]),
                  let rawTitle = object["title"]?.stringValue,
                  let rawKind = object["sourceKind"]?.stringValue,
                  let sourceKind = TaskSourceKind(rawValue: rawKind),
                  let rawSourceText = object["sourceText"]?.stringValue
            else {
                throw CodexRealtimeError.invalidNotification("item/tool/call")
            }
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let sourceText = rawSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty,
                  title.count <= 80,
                  !sourceText.isEmpty,
                  sourceText.count <= 20_000
            else {
                throw CodexRealtimeError.invalidNotification("item/tool/call")
            }
            return LiveTaskDraft(
                threadID: call.threadID,
                callID: call.callID,
                projectID: projectID,
                title: title,
                sourceKind: sourceKind,
                sourceText: sourceText
            )
        }
    }
}

enum RealtimeAudioWireCodec {
    static let sampleRate: UInt32 = 24_000
    private static let maximumFramesPerChunk = Int(sampleRate) * 10

    static func encodeCapture(_ buffer: RealtimeAudioBuffer) throws -> CodexRealtimeAudioChunk {
        guard buffer.encoding == .float32Interleaved,
              buffer.channelCount == 1,
              buffer.frameCount > 0
        else { throw CodexRealtimeError.invalidAudioChunk }

        let inputCount = Int(buffer.frameCount)
        var samples = [Float](repeating: 0, count: inputCount)
        buffer.data.withUnsafeBytes { bytes in
            for index in 0..<inputCount {
                let bits = bytes.loadUnaligned(
                    fromByteOffset: index * MemoryLayout<Float>.size,
                    as: UInt32.self
                )
                samples[index] = Float(bitPattern: UInt32(littleEndian: bits))
            }
        }

        let scaledOutputCount = Double(inputCount) * Double(sampleRate) / buffer.sampleRate
        guard scaledOutputCount.isFinite,
              scaledOutputCount >= 1,
              scaledOutputCount <= Double(maximumFramesPerChunk)
        else { throw CodexRealtimeError.invalidAudioChunk }
        let outputCount = Int(scaledOutputCount.rounded(.down))
        var pcm = [UInt16](repeating: 0, count: outputCount)
        let sourceStep = buffer.sampleRate / Double(sampleRate)
        for outputIndex in 0..<outputCount {
            let sourcePosition = min(Double(inputCount - 1), Double(outputIndex) * sourceStep)
            let lower = Int(sourcePosition.rounded(.down))
            let upper = min(inputCount - 1, lower + 1)
            let fraction = Float(sourcePosition - Double(lower))
            let interpolated = samples[lower] + (samples[upper] - samples[lower]) * fraction
            let finiteSample = interpolated.isFinite ? interpolated : 0
            let clamped = max(-1, min(1, finiteSample))
            let signed = Int16((clamped * 32_767).rounded())
            pcm[outputIndex] = UInt16(bitPattern: signed).littleEndian
        }
        let data = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
        return try CodexRealtimeAudioChunk(
            data: data,
            sampleRate: sampleRate,
            channelCount: 1,
            samplesPerChannel: UInt32(outputCount)
        )
    }

    static func decodePlayback(_ chunk: CodexRealtimeAudioChunk) throws -> RealtimeAudioBuffer {
        let channels = Int(chunk.channelCount)
        let bytesPerFrame = channels * MemoryLayout<Int16>.size
        guard chunk.data.count.isMultiple(of: bytesPerFrame) else {
            throw CodexRealtimeError.invalidAudioChunk
        }
        let frames = chunk.data.count / bytesPerFrame
        if let declared = chunk.samplesPerChannel, Int(declared) != frames {
            throw CodexRealtimeError.invalidAudioChunk
        }

        var samples = [Float](repeating: 0, count: frames * channels)
        chunk.data.withUnsafeBytes { bytes in
            for index in samples.indices {
                let stored = bytes.loadUnaligned(
                    fromByteOffset: index * MemoryLayout<Int16>.size,
                    as: UInt16.self
                )
                let signed = Int16(bitPattern: UInt16(littleEndian: stored))
                samples[index] = Float(signed) / 32_768
            }
        }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        return try RealtimeAudioBuffer(
            data: data,
            sampleRate: Double(chunk.sampleRate),
            channelCount: UInt32(chunk.channelCount),
            frameCount: UInt32(frames)
        )
    }

    static func silence(milliseconds: UInt32 = 400) throws -> CodexRealtimeAudioChunk {
        guard (1...2_000).contains(milliseconds) else {
            throw CodexRealtimeError.invalidAudioChunk
        }
        let frames = sampleRate * milliseconds / 1_000
        return try CodexRealtimeAudioChunk(
            data: Data(count: Int(frames) * MemoryLayout<Int16>.size),
            sampleRate: sampleRate,
            channelCount: 1,
            samplesPerChannel: frames
        )
    }
}
