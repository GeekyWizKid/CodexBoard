import Foundation

enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        switch self {
        case let .integer(value): Int(exactly: value)
        case let .number(value): Int(exactly: value)
        default: nil
        }
    }

    var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}

struct RPCErrorPayload: Codable, Equatable, Sendable {
    let code: Int
    let message: String
}

struct RPCMessage: Sendable {
    let id: JSONValue?
    let method: String?
    let params: JSONValue?
    let result: JSONValue?
    let error: RPCErrorPayload?
}

struct RPCMessageParser: Sendable {
    func parse(_ data: Data) throws -> RPCMessage {
        struct WireMessage: Decodable {
            let id: JSONValue?
            let method: String?
            let params: JSONValue?
            let result: JSONValue?
            let error: RPCErrorPayload?
        }

        let wire = try JSONDecoder().decode(WireMessage.self, from: data)
        return RPCMessage(
            id: wire.id,
            method: wire.method,
            params: wire.params,
            result: wire.result,
            error: wire.error
        )
    }
}

enum CodexConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

struct CodexThreadSummary: Equatable, Sendable {
    let id: String
    let sessionID: String
    let cwd: String
    let name: String?
    let createdAt: Date
    let updatedAt: Date
    let isPinned: Bool
    let statusType: String
    let sourceKind: String

    var isActive: Bool { statusType == "active" }
}

struct CodexThreadPage: Equatable, Sendable {
    let threads: [CodexThreadSummary]
    let nextCursor: String?
}

struct CodexReasoningEffortOption: Equatable, Sendable {
    let effort: ReasoningEffort
    let description: String
}

enum CodexServiceTier {
    static let standard = "default"
    static let fast = "priority"
}

struct CodexModelServiceTier: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let description: String
}

struct CodexModel: Identifiable, Equatable, Sendable {
    let id: String
    let model: String
    let displayName: String
    let description: String
    let isDefault: Bool
    let defaultReasoningEffort: ReasoningEffort
    let supportedReasoningEfforts: [CodexReasoningEffortOption]
    let serviceTiers: [CodexModelServiceTier]

    var supportsFast: Bool {
        serviceTiers.contains { $0.id == CodexServiceTier.fast }
    }
}

struct CodexStartedThread: Equatable, Sendable {
    let threadID: String
    let sessionID: String
    let model: String
    let cwd: String
}

struct CodexStartedTurn: Equatable, Sendable {
    let turnID: String
    let status: String
}

enum CodexTurnInput: Equatable, Sendable {
    case text(String)
    case localImage(path: String)

    var wireValue: JSONValue {
        switch self {
        case let .text(text):
            .object([
                "type": .string("text"),
                "text": .string(text)
            ])
        case let .localImage(path):
            .object([
                "type": .string("localImage"),
                "path": .string(path)
            ])
        }
    }
}

enum CodexEvent: Sendable {
    case agentDelta(threadID: String, turnID: String, delta: String)
    case agentFinal(threadID: String, turnID: String, text: String)
    case planFinal(threadID: String, turnID: String, text: String)
    case planUpdated(threadID: String, turnID: String, explanation: String?, steps: [CodexPlanStep])
    case turnCompleted(threadID: String, turnID: String, status: String, error: String?)
    case activity(threadID: String, turnID: String, message: String)
    case configurationWarning(threadID: String?, turnID: String?, message: String)
    case warning(threadID: String?, turnID: String?, message: String)
    case threadStatus(threadID: String, status: String)
    case connectionLost(message: String)
}

enum CodexClientError: LocalizedError, Equatable {
    case executableNotFound
    case processLaunchFailed
    case disconnected
    case transportWriteFailed
    case invalidResponse(String)
    case requestTimedOut(String)
    case processExited(Int32)
    case rpc(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound: "找不到本机 Codex CLI。"
        case .processLaunchFailed: "无法启动 Codex app-server。"
        case .disconnected: "Codex app-server 已断开。"
        case .transportWriteFailed: "无法向 Codex app-server 发送请求。"
        case let .invalidResponse(detail): "Codex app-server 返回了无效响应：\(detail)"
        case let .requestTimedOut(method): "Codex 请求超时：\(method)"
        case let .processExited(status): "Codex app-server 已退出（状态 \(status)）。"
        case let .rpc(code, message): "Codex 错误 \(code)：\(message)"
        }
    }
}
