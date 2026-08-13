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

struct CodexSkillMetadata: Identifiable, Hashable, Sendable {
    var id: String { path }

    let name: String
    let description: String
    let shortDescription: String?
    let path: String
    let scope: String
    let enabled: Bool
}

struct CodexAppToolSummary: Identifiable, Hashable, Sendable {
    var id: String { name }

    let name: String
    let title: String?
    let description: String
    let isEnabled: Bool
    let isReadOnly: Bool
    let disabledReason: String?
}

struct CodexApp: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let invocationName: String
    let description: String
    let isAccessible: Bool
    let isEnabled: Bool
    let isCallable: Bool
    let tools: [CodexAppToolSummary]

    var enabledTools: [CodexAppToolSummary] {
        tools.filter(\.isEnabled)
    }

    var supportsReadOnlyUse: Bool {
        isEnabled
            && isCallable
            && !enabledTools.isEmpty
            && enabledTools.allSatisfy(\.isReadOnly)
    }

    var containsWriteTools: Bool {
        enabledTools.contains { !$0.isReadOnly }
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
    case skill(name: String, path: String)
    case mention(name: String, path: String)

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
        case let .skill(name, path):
            .object([
                "type": .string("skill"),
                "name": .string(name),
                "path": .string(path)
            ])
        case let .mention(name, path):
            .object([
                "type": .string("mention"),
                "name": .string(name),
                "path": .string(path)
            ])
        }
    }
}

enum CodexRequestID: Hashable, Sendable {
    case string(String)
    case integer(Int64)

    var displayValue: String {
        switch self {
        case let .string(value): value
        case let .integer(value): String(value)
        }
    }
}

enum CodexApprovalDecision: String, CaseIterable, Hashable, Sendable {
    case accept
    case acceptForSession
    case decline
    case cancel
}

struct CodexCommandApproval: Equatable, Sendable {
    let command: String?
    let cwd: String?
    let reason: String?
    let commandActions: JSONValue?
    let requestedPermissions: JSONValue?
    let availableDecisions: [CodexApprovalDecision]?
}

struct CodexFileChangeApproval: Equatable, Sendable {
    let reason: String?
    let grantRoot: String?
}

struct CodexUserInputOption: Hashable, Sendable {
    let label: String
    let description: String
}

struct CodexUserInputQuestion: Identifiable, Hashable, Sendable {
    let id: String
    let header: String
    let question: String
    let isOther: Bool
    let isSecret: Bool
    let options: [CodexUserInputOption]?
}

struct CodexUserInputRequest: Equatable, Sendable {
    let questions: [CodexUserInputQuestion]
    let isBlocking: Bool
}

struct CodexPermissionsApproval: Equatable, Sendable {
    let cwd: String
    let reason: String?
    let permissions: JSONValue
}

enum CodexMCPElicitationMode: String, Hashable, Sendable {
    case form
    case openAIForm = "openai/form"
    case url
}

struct CodexMCPElicitation: Equatable, Sendable {
    let serverName: String
    let mode: CodexMCPElicitationMode
    let message: String
    let requestedSchema: JSONValue?
    let url: URL?
    let elicitationID: String?
    let metadata: JSONValue?
}

struct CodexInteractionRequest: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case commandApproval(CodexCommandApproval)
        case fileChangeApproval(CodexFileChangeApproval)
        case userInput(CodexUserInputRequest)
        case permissionsApproval(CodexPermissionsApproval)
        case mcpElicitation(CodexMCPElicitation)
    }

    let id: CodexRequestID
    let threadID: String
    let turnID: String?
    let itemID: String?
    let kind: Kind
    let createdAt: Date
}

enum CodexPermissionScope: String, Hashable, Sendable {
    case turn
    case session
}

enum CodexPermissionDecision: Equatable, Sendable {
    case deny(scope: CodexPermissionScope)
    case grant(permissions: JSONValue, scope: CodexPermissionScope)
}

enum CodexMCPElicitationResponse: Equatable, Sendable {
    case accept(content: JSONValue, metadata: JSONValue?)
    case acceptURL
    case decline
    case cancel
}

enum CodexInteractionResponse: Equatable, Sendable {
    case approval(CodexApprovalDecision)
    case userInput([String: [String]])
    case permissions(CodexPermissionDecision)
    case mcpElicitation(CodexMCPElicitationResponse)
}

struct CodexMCPServerStatus: Identifiable, Hashable, Sendable {
    var id: String { name }

    let name: String
    let authStatus: String
    let title: String?
    let description: String?
    let version: String?
    let websiteURL: URL?
    let toolNames: [String]
}

struct CodexMCPOAuthCompletion: Equatable, Sendable {
    let serverName: String
    let threadID: String?
    let success: Bool
    let error: String?
}

enum CodexEvent: Sendable {
    case agentDelta(threadID: String, turnID: String, delta: String)
    case agentFinal(threadID: String, turnID: String, text: String)
    case turnDiffUpdated(threadID: String, turnID: String, diff: String)
    case planFinal(threadID: String, turnID: String, text: String)
    case planUpdated(threadID: String, turnID: String, explanation: String?, steps: [CodexPlanStep])
    case turnCompleted(threadID: String, turnID: String, status: String, error: String?)
    case activity(threadID: String, turnID: String, message: String)
    case configurationWarning(threadID: String?, turnID: String?, message: String)
    case warning(threadID: String?, turnID: String?, message: String)
    case threadStatus(threadID: String, status: String)
    case interactionRequested(CodexInteractionRequest)
    case interactionResolved(threadID: String, requestID: CodexRequestID)
    case mcpOAuthCompleted(CodexMCPOAuthCompletion)
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
