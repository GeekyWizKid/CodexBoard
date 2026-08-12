import Foundation

@MainActor
final class CodexAppServerClient: ObservableObject, @unchecked Sendable {
    @Published private(set) var connectionState: CodexConnectionState = .disconnected
    @Published private(set) var lastError: String?

    private struct PendingRequest {
        let method: String
        let continuation: CheckedContinuation<JSONValue, Error>
        var timeoutTask: Task<Void, Never>?
    }

    private let resolver: CodexExecutableResolver
    private let parser = RPCMessageParser()
    private let requestTimeout: TimeInterval
    private var transport: AppServerTransport?
    private var connectWaiters: [CheckedContinuation<Void, Error>] = []
    private var nextRequestID = 1
    private var pendingRequests: [Int: PendingRequest] = [:]
    private var eventContinuation: AsyncStream<CodexEvent>.Continuation?

    lazy var events: AsyncStream<CodexEvent> = AsyncStream { [weak self] continuation in
        Task { @MainActor [weak self] in
            self?.eventContinuation = continuation
        }
    }

    init(
        resolver: CodexExecutableResolver = CodexExecutableResolver(),
        requestTimeout: TimeInterval = 30
    ) {
        self.resolver = resolver
        self.requestTimeout = max(1, requestTimeout)
    }

    deinit {
        transport?.stop()
        eventContinuation?.finish()
    }

    func connect() async throws {
        if connectionState == .connected { return }
        if connectionState == .connecting {
            return try await withCheckedThrowingContinuation { continuation in
                connectWaiters.append(continuation)
            }
        }
        connectionState = .connecting
        lastError = nil
        let resolver = resolver
        do {
            let executable = try await Task.detached(priority: .userInitiated) {
                try resolver.resolve()
            }.value
            let newTransport = AppServerTransport(executableURL: executable)
            newTransport.delegate = self
            transport = newTransport
            try newTransport.start()
            _ = try await request(method: "initialize", params: .object([
                "clientInfo": .object([
                    "name": .string("codex_board"),
                    "title": .string("CodexBoard"),
                    "version": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")
                ]),
                "capabilities": .object([
                    "experimentalApi": .bool(true)
                ])
            ]))
            try notify(method: "initialized", params: .object([:]))
            connectionState = .connected
            resumeConnectWaiters()
        } catch {
            let normalized = normalize(error)
            lastError = normalized.localizedDescription
            connectionState = .failed(normalized.localizedDescription)
            disconnect(failingWith: normalized)
            resumeConnectWaiters(throwing: normalized)
            throw normalized
        }
    }

    func disconnect() {
        disconnect(failingWith: .disconnected)
        connectionState = .disconnected
    }

    func verifyAccount() async throws -> Bool {
        try await ensureConnected()
        let value = try await request(method: "account/read", params: .object([
            "refreshToken": .bool(false)
        ]))
        guard let account = value["account"] else { return false }
        if case .null = account { return false }
        return true
    }

    func listThreads(cursor: String?, archived: Bool) async throws -> CodexThreadPage {
        try await ensureConnected()
        var params: [String: JSONValue] = [
            "limit": .integer(100),
            "sortKey": .string("recency_at"),
            "sortDirection": .string("desc"),
            "sourceKinds": .array(["cli", "vscode", "exec", "appServer", "unknown"].map(JSONValue.string)),
            "archived": .bool(archived),
            "useStateDbOnly": .bool(true)
        ]
        if let cursor { params["cursor"] = .string(cursor) }
        let value = try await request(method: "thread/list", params: .object(params))
        let threads = value["data"]?.arrayValue?.compactMap(Self.parseThread) ?? []
        let nextCursor: String?
        if let cursorValue = value["nextCursor"] {
            nextCursor = cursorValue.stringValue
        } else {
            nextCursor = nil
        }
        return CodexThreadPage(threads: threads, nextCursor: nextCursor)
    }

    func startThread(cwd: String, model: String?) async throws -> CodexStartedThread {
        try await ensureConnected()
        var params: [String: JSONValue] = [
            "cwd": .string(cwd),
            "approvalPolicy": .string("never"),
            "sandbox": .string("read-only"),
            "personality": .string("pragmatic"),
            "serviceName": .string("codex_board"),
            "ephemeral": .bool(false),
            "runtimeWorkspaceRoots": .array([.string(cwd)])
        ]
        if let model, !model.isEmpty { params["model"] = .string(model) }
        let value = try await request(method: "thread/start", params: .object(params))
        guard let thread = value["thread"],
              let threadID = thread["id"]?.stringValue,
              let sessionID = thread["sessionId"]?.stringValue,
              let actualCWD = value["cwd"]?.stringValue,
              let actualModel = value["model"]?.stringValue
        else {
            throw CodexClientError.invalidResponse("thread/start 缺少 thread/session/cwd/model")
        }
        return CodexStartedThread(threadID: threadID, sessionID: sessionID, model: actualModel, cwd: actualCWD)
    }

    func resumeThread(threadID: String, cwd: String) async throws -> CodexStartedThread {
        try await ensureConnected()
        let value = try await request(method: "thread/resume", params: .object([
            "threadId": .string(threadID),
            "cwd": .string(cwd),
            "runtimeWorkspaceRoots": .array([.string(cwd)])
        ]))
        guard let thread = value["thread"],
              let resultThreadID = thread["id"]?.stringValue,
              let sessionID = thread["sessionId"]?.stringValue,
              let actualCWD = value["cwd"]?.stringValue,
              let actualModel = value["model"]?.stringValue
        else {
            throw CodexClientError.invalidResponse("thread/resume 缺少 thread/session/cwd/model")
        }
        return CodexStartedThread(threadID: resultThreadID, sessionID: sessionID, model: actualModel, cwd: actualCWD)
    }

    func setThreadName(threadID: String, name: String) async throws {
        _ = try await request(method: "thread/name/set", params: .object([
            "threadId": .string(threadID),
            "name": .string(name)
        ]))
    }

    func startPlanningTurn(
        threadID: String,
        cwd: String,
        prompt: String,
        model: String,
        effort: ReasoningEffort
    ) async throws -> CodexStartedTurn {
        try await startTurn(
            threadID: threadID,
            cwd: cwd,
            prompt: prompt,
            model: model,
            effort: effort,
            mode: "plan",
            sandboxPolicy: .object([
                "type": .string("readOnly"),
                "networkAccess": .bool(false)
            ]),
            approvalPolicy: "never"
        )
    }

    func startExecutionTurn(
        threadID: String,
        cwd: String,
        prompt: String,
        model: String,
        effort: ReasoningEffort,
        allowNetwork: Bool
    ) async throws -> CodexStartedTurn {
        try await startTurn(
            threadID: threadID,
            cwd: cwd,
            prompt: prompt,
            model: model,
            effort: effort,
            mode: "default",
            sandboxPolicy: .object([
                "type": .string("workspaceWrite"),
                "writableRoots": .array([.string(cwd)]),
                "networkAccess": .bool(allowNetwork),
                "excludeTmpdirEnvVar": .bool(true),
                "excludeSlashTmp": .bool(true)
            ]),
            approvalPolicy: "never"
        )
    }

    func interrupt(threadID: String, turnID: String) async throws {
        _ = try await request(method: "turn/interrupt", params: .object([
            "threadId": .string(threadID),
            "turnId": .string(turnID)
        ]))
    }

    private func startTurn(
        threadID: String,
        cwd: String,
        prompt: String,
        model: String,
        effort: ReasoningEffort,
        mode: String,
        sandboxPolicy: JSONValue,
        approvalPolicy: String
    ) async throws -> CodexStartedTurn {
        var params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "input": .array([.object([
                "type": .string("text"),
                "text": .string(prompt)
            ])]),
            "cwd": .string(cwd),
            "effort": .string(effort.rawValue),
            "summary": .string("concise"),
            "personality": .string("pragmatic"),
            "approvalPolicy": .string(approvalPolicy),
            "sandboxPolicy": sandboxPolicy,
            "runtimeWorkspaceRoots": .array([.string(cwd)]),
            "collaborationMode": .object([
                "mode": .string(mode),
                "settings": .object([
                    "model": .string(model),
                    "reasoning_effort": .string(effort.rawValue),
                    "developer_instructions": .null
                ])
            ]),
            "responsesapiClientMetadata": .object([
                "codex_board": .string("true")
            ])
        ]
        if !model.isEmpty { params["model"] = .string(model) }
        let value = try await request(method: "turn/start", params: .object(params))
        guard let turn = value["turn"],
              let turnID = turn["id"]?.stringValue,
              let status = turn["status"]?.stringValue
        else {
            throw CodexClientError.invalidResponse("turn/start 缺少 turn id/status")
        }
        return CodexStartedTurn(turnID: turnID, status: status)
    }

    private func ensureConnected() async throws {
        if connectionState != .connected { try await connect() }
    }

    private func request(method: String, params: JSONValue? = nil) async throws -> JSONValue {
        guard let transport else { throw CodexClientError.disconnected }
        let id = nextRequestID
        nextRequestID += 1
        var object: [String: JSONValue] = [
            "id": .integer(Int64(id)),
            "method": .string(method)
        ]
        if let params { object["params"] = params }
        let data = try JSONEncoder().encode(JSONValue.object(object))

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = PendingRequest(method: method, continuation: continuation, timeoutTask: nil)
            let timeoutTask = Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.requestTimeout))
                guard !Task.isCancelled, let pending = self.pendingRequests.removeValue(forKey: id) else { return }
                pending.continuation.resume(throwing: CodexClientError.requestTimedOut(method))
            }
            pendingRequests[id]?.timeoutTask = timeoutTask
            do {
                try transport.send(data)
            } catch {
                let pending = pendingRequests.removeValue(forKey: id)
                pending?.timeoutTask?.cancel()
                pending?.continuation.resume(throwing: normalize(error))
            }
        }
    }

    private func notify(method: String, params: JSONValue? = nil) throws {
        guard let transport else { throw CodexClientError.disconnected }
        var object: [String: JSONValue] = ["method": .string(method)]
        if let params { object["params"] = params }
        try transport.send(try JSONEncoder().encode(JSONValue.object(object)))
    }

    private func respond(id: JSONValue, result: JSONValue) throws {
        guard let transport else { throw CodexClientError.disconnected }
        try transport.send(try JSONEncoder().encode(JSONValue.object([
            "id": id,
            "result": result
        ])))
    }

    private func receive(_ data: Data) {
        let message: RPCMessage
        do {
            message = try parser.parse(data)
        } catch {
            lastError = "无法解析 Codex 事件。"
            return
        }

        if message.method == nil,
           let id = message.id?.intValue,
           let pending = pendingRequests.removeValue(forKey: id) {
            pending.timeoutTask?.cancel()
            if let error = message.error {
                pending.continuation.resume(throwing: CodexClientError.rpc(code: error.code, message: error.message))
            } else if let result = message.result {
                pending.continuation.resume(returning: result)
            } else {
                pending.continuation.resume(throwing: CodexClientError.invalidResponse(pending.method))
            }
            return
        }

        guard let method = message.method else { return }
        if let id = message.id {
            handleServerRequest(id: id, method: method, params: message.params)
            return
        }
        handleNotification(method: method, params: message.params)
    }

    private func handleServerRequest(id: JSONValue, method: String, params: JSONValue?) {
        do {
            switch method {
            case "currentTime/read":
                try respond(id: id, result: .object([
                    "currentTimeAt": .integer(Int64(Date().timeIntervalSince1970))
                ]))
            case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
                try respond(id: id, result: .object(["decision": .string("decline")]))
                emitWarning(params: params, message: "Codex 请求了超出当前任务沙箱的操作，已自动拒绝。")
            case "item/tool/requestUserInput":
                var answers: [String: JSONValue] = [:]
                for question in params?["questions"]?.arrayValue ?? [] {
                    if let questionID = question["id"]?.stringValue {
                        answers[questionID] = .object(["answers": .array([])])
                    }
                }
                try respond(id: id, result: .object(["answers": .object(answers)]))
                emitWarning(params: params, message: "任务需要补充输入；请在 CodexBoard 中检查并重新规划。")
            case "item/permissions/requestApproval":
                try respond(id: id, result: .object([
                    "permissions": .object([:]),
                    "scope": .string("turn")
                ]))
                emitWarning(params: params, message: "Codex 请求了额外权限，已拒绝扩大当前任务边界。")
            case "mcpServer/elicitation/request":
                try respond(id: id, result: .object([
                    "action": .string("cancel"),
                    "content": .null,
                    "_meta": .null
                ]))
                emitWarning(params: params, message: "外部工具请求了额外输入，已取消并暂停自动推断。")
            case "applyPatchApproval", "execCommandApproval":
                try respond(id: id, result: .object([
                    "decision": .object([
                        "denied": .object(["rejection": .string("CodexBoard does not grant sandbox escapes.")])
                    ])
                ]))
                emitWarning(params: params, message: "旧版 Codex 请求了沙箱外操作，已拒绝。")
            default:
                try respond(id: id, result: .object([:]))
                emitWarning(params: params, message: "未支持的 Codex 请求已安全忽略：\(method)")
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func handleNotification(method: String, params: JSONValue?) {
        guard let params else { return }
        let threadID = params["threadId"]?.stringValue
        let turnID = params["turnId"]?.stringValue
        switch method {
        case "item/agentMessage/delta":
            guard let threadID, let turnID, let delta = params["delta"]?.stringValue else { return }
            eventContinuation?.yield(.agentDelta(threadID: threadID, turnID: turnID, delta: delta))
        case "turn/plan/updated":
            guard let threadID, let turnID else { return }
            let explanation = params["explanation"]?.stringValue
            let steps = params["plan"]?.arrayValue?.compactMap { value -> CodexPlanStep? in
                guard let step = value["step"]?.stringValue,
                      let rawStatus = value["status"]?.stringValue,
                      let status = CodexPlanStep.Status(rawValue: rawStatus)
                else { return nil }
                return CodexPlanStep(step: step, status: status)
            } ?? []
            eventContinuation?.yield(.planUpdated(threadID: threadID, turnID: turnID, explanation: explanation, steps: steps))
        case "turn/completed":
            guard let threadID, let turn = params["turn"],
                  let completedTurnID = turn["id"]?.stringValue,
                  let status = turn["status"]?.stringValue
            else { return }
            let error = Self.turnErrorDescription(turn["error"])
            eventContinuation?.yield(.turnCompleted(threadID: threadID, turnID: completedTurnID, status: status, error: error))
        case "item/started":
            guard let threadID, let turnID, let item = params["item"], let type = item["type"]?.stringValue else { return }
            eventContinuation?.yield(.activity(threadID: threadID, turnID: turnID, message: Self.activityLabel(type: type, item: item)))
        case "item/completed":
            guard let threadID, let turnID, let item = params["item"], let type = item["type"]?.stringValue else { return }
            if type == "plan", let text = item["text"]?.stringValue {
                eventContinuation?.yield(.planFinal(threadID: threadID, turnID: turnID, text: text))
            } else if type == "agentMessage", let text = item["text"]?.stringValue {
                eventContinuation?.yield(.agentFinal(threadID: threadID, turnID: turnID, text: text))
            }
            eventContinuation?.yield(.activity(threadID: threadID, turnID: turnID, message: "已完成：\(Self.activityLabel(type: type, item: item))"))
        case "thread/status/changed":
            guard let threadID, let status = params["status"]?["type"]?.stringValue else { return }
            eventContinuation?.yield(.threadStatus(threadID: threadID, status: status))
        case "warning", "guardianWarning", "configWarning":
            let message = params["message"]?.stringValue ?? method
            eventContinuation?.yield(.warning(threadID: threadID, turnID: turnID, message: message))
        case "error":
            let message = Self.turnErrorDescription(params["error"]) ?? "Codex 执行错误"
            eventContinuation?.yield(.warning(threadID: threadID, turnID: turnID, message: message))
        default:
            break
        }
    }

    private func emitWarning(params: JSONValue?, message: String) {
        eventContinuation?.yield(.warning(
            threadID: params?["threadId"]?.stringValue,
            turnID: params?["turnId"]?.stringValue,
            message: message
        ))
    }

    private static func parseThread(_ value: JSONValue) -> CodexThreadSummary? {
        guard let id = value["id"]?.stringValue,
              let sessionID = value["sessionId"]?.stringValue,
              let cwd = value["cwd"]?.stringValue,
              let created = value["createdAt"]?.intValue,
              let updated = value["recencyAt"]?.intValue ?? value["updatedAt"]?.intValue
        else { return nil }
        return CodexThreadSummary(
            id: id,
            sessionID: sessionID,
            cwd: cwd,
            name: value["name"]?.stringValue,
            createdAt: Date(timeIntervalSince1970: TimeInterval(created)),
            updatedAt: Date(timeIntervalSince1970: TimeInterval(updated)),
            isPinned: value["isPinned"]?.boolValue ?? false,
            statusType: value["status"]?["type"]?.stringValue ?? "notLoaded",
            sourceKind: Self.sourceKind(value["source"])
        )
    }

    private static func sourceKind(_ value: JSONValue?) -> String {
        if let source = value?.stringValue { return source }
        guard let object = value?.objectValue else { return "unknown" }
        return object.keys.first ?? "unknown"
    }

    private static func activityLabel(type: String, item: JSONValue) -> String {
        switch type {
        case "reasoning": return "正在分析"
        case "commandExecution":
            if let command = item["command"]?.stringValue {
                return "运行：\(command.prefix(100))"
            }
            return "正在运行命令"
        case "fileChange": return "正在修改文件"
        case "mcpToolCall": return "正在调用工具"
        case "collabAgentToolCall": return "正在协调子任务"
        case "webSearch": return "正在搜索资料"
        case "plan": return "正在整理方案"
        case "agentMessage": return "正在撰写结果"
        default: return type
        }
    }

    private static func turnErrorDescription(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        if let message = value["message"]?.stringValue { return message }
        if let info = value["additionalDetails"]?.stringValue { return info }
        if let string = value.stringValue { return string }
        return nil
    }

    private func normalize(_ error: Error) -> CodexClientError {
        if let error = error as? CodexClientError { return error }
        return .invalidResponse(error.localizedDescription)
    }

    private func resumeConnectWaiters(throwing error: Error? = nil) {
        let waiters = connectWaiters
        connectWaiters.removeAll()
        for waiter in waiters {
            if let error {
                waiter.resume(throwing: error)
            } else {
                waiter.resume()
            }
        }
    }

    private func disconnect(failingWith error: CodexClientError) {
        let oldTransport = transport
        transport = nil
        oldTransport?.delegate = nil
        oldTransport?.stop()
        let pending = pendingRequests.values
        pendingRequests.removeAll()
        for request in pending {
            request.timeoutTask?.cancel()
            request.continuation.resume(throwing: error)
        }
    }
}

extension CodexAppServerClient: AppServerTransportDelegate {
    nonisolated func transportDidReceive(_ data: Data) {
        MainActor.assumeIsolated { [weak self] in self?.receive(data) }
    }

    nonisolated func transportDidExit(status: Int32) {
        MainActor.assumeIsolated { [weak self] in
            guard let self, self.transport != nil else { return }
            let error = CodexClientError.processExited(status)
            self.lastError = error.localizedDescription
            self.connectionState = .failed(error.localizedDescription)
            self.disconnect(failingWith: error)
            self.eventContinuation?.yield(.connectionLost(message: error.localizedDescription))
        }
    }
}
