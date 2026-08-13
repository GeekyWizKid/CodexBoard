import Foundation

@MainActor
final class CodexAppServerClient: ObservableObject, @unchecked Sendable {
    static let mcpServerStatusListMethod = "mcpServerStatus/list"
    static let mcpOAuthLoginMethod = "mcpServer/oauth/login"
    static let mcpOAuthCompletionMethod = "mcpServer/oauthLogin/completed"

    @Published private(set) var connectionState: CodexConnectionState = .disconnected
    @Published private(set) var lastError: String?

    private struct PendingRequest {
        let method: String
        let continuation: CheckedContinuation<JSONValue, Error>
        var timeoutTask: Task<Void, Never>?
    }

    private struct PendingInteraction {
        let method: String
        let request: CodexInteractionRequest
    }

    struct AppListPage: Equatable {
        let apps: [ParsedAppInfo]
        let nextCursor: String?
    }

    struct ParsedAppInfo: Equatable {
        let id: String
        let name: String
        let description: String?
        let isAccessible: Bool
        let isEnabled: Bool
    }

    struct ParsedInstalledApp: Equatable {
        let id: String
        let isEnabled: Bool
        let isCallable: Bool
        let runtimeName: String?
    }

    struct ParsedConnectorMetadata: Equatable {
        let id: String
        let name: String?
        let description: String?
        let tools: [CodexAppToolSummary]
    }

    struct MCPServerPage: Equatable {
        let servers: [CodexMCPServerStatus]
        let nextCursor: String?
    }

    private let resolver: CodexExecutableResolver
    private let parser = RPCMessageParser()
    private let requestTimeout: TimeInterval
    private var transport: AppServerTransport?
    private var connectWaiters: [CheckedContinuation<Void, Error>] = []
    private var nextRequestID = 1
    private var pendingRequests: [Int: PendingRequest] = [:]
    private var pendingInteractions: [CodexRequestID: PendingInteraction] = [:]
    private var eventContinuation: AsyncStream<CodexEvent>.Continuation?

    var pendingInteractionIDs: Set<CodexRequestID> {
        Set(pendingInteractions.keys)
    }

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
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
            _ = try await request(method: "initialize", params: Self.makeInitializeParams(version: version))
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

    func listModels() async throws -> [CodexModel] {
        try await ensureConnected()
        var models: [CodexModel] = []
        var cursor: String?
        var seenCursors: Set<String> = []

        repeat {
            var params: [String: JSONValue] = [
                "limit": .integer(100),
                "includeHidden": .bool(false)
            ]
            if let cursor { params["cursor"] = .string(cursor) }
            let value = try await request(method: "model/list", params: .object(params))
            guard let data = value["data"]?.arrayValue else {
                throw CodexClientError.invalidResponse("model/list 缺少 data")
            }
            models.append(contentsOf: data.compactMap(Self.parseModel))
            cursor = value["nextCursor"]?.stringValue
            if let cursor, !seenCursors.insert(cursor).inserted {
                throw CodexClientError.invalidResponse("model/list 返回了重复 cursor")
            }
        } while cursor != nil

        return models
    }

    func listSkills(cwds: [String], forceReload: Bool) async throws -> [String: [CodexSkillMetadata]] {
        try await ensureConnected()
        let value = try await request(
            method: "skills/list",
            params: Self.makeSkillsListParams(cwds: cwds, forceReload: forceReload)
        )
        return try Self.parseSkillsListResponse(value)
    }

    func listApps(forceRefresh: Bool) async throws -> [CodexApp] {
        try await listApps(forceRefresh: forceRefresh, threadID: nil)
    }

    func listApps(forceRefresh: Bool, threadID: String?) async throws -> [CodexApp] {
        try await ensureConnected()
        var listedApps: [ParsedAppInfo] = []
        var cursor: String?
        var seenCursors: Set<String> = []
        var isFirstPage = true

        repeat {
            let value = try await request(
                method: "app/list",
                params: Self.makeAppsListParams(
                    cursor: cursor,
                    forceRefetch: isFirstPage && forceRefresh,
                    threadID: threadID
                )
            )
            let page = try Self.parseAppListResponse(value)
            listedApps.append(contentsOf: page.apps)
            cursor = page.nextCursor
            if let cursor, !seenCursors.insert(cursor).inserted {
                throw CodexClientError.invalidResponse("app/list 返回了重复 cursor")
            }
            isFirstPage = false
        } while cursor != nil

        let installedValue = try await request(
            method: "app/installed",
            params: Self.makeAppsInstalledParams(
                forceRefresh: forceRefresh,
                threadID: threadID
            )
        )
        let installedApps = try Self.parseAppsInstalledResponse(installedValue)

        var seenAppIDs: Set<String> = []
        let accessibleAppIDs = listedApps.compactMap { app -> String? in
            guard app.isAccessible, seenAppIDs.insert(app.id).inserted else { return nil }
            return app.id
        }
        var connectorMetadata: [ParsedConnectorMetadata] = []
        for appIDs in Self.appIDBatches(accessibleAppIDs) {
            let value = try await request(
                method: "app/read",
                params: Self.makeAppsReadParams(appIDs: appIDs)
            )
            connectorMetadata.append(contentsOf: try Self.parseAppsReadResponse(value))
        }

        return Self.mergeApps(
            listed: listedApps,
            installed: installedApps,
            metadata: connectorMetadata
        )
    }

    func listMCPServers(threadID: String?) async throws -> [CodexMCPServerStatus] {
        try await ensureConnected()
        var servers: [CodexMCPServerStatus] = []
        var cursor: String?
        var seenCursors: Set<String> = []

        repeat {
            let value = try await request(
                method: Self.mcpServerStatusListMethod,
                params: Self.makeMCPServerListParams(cursor: cursor, threadID: threadID)
            )
            let page = try Self.parseMCPServerListResponse(value)
            servers.append(contentsOf: page.servers)
            cursor = page.nextCursor
            if let cursor, !seenCursors.insert(cursor).inserted {
                throw CodexClientError.invalidResponse("mcpServerStatus/list 返回了重复 cursor")
            }
        } while cursor != nil

        var seenNames: Set<String> = []
        return servers.filter { seenNames.insert($0.name).inserted }
    }

    func beginMCPOAuth(serverName: String, threadID: String?) async throws -> URL {
        try await ensureConnected()
        let value = try await request(
            method: Self.mcpOAuthLoginMethod,
            params: Self.makeMCPOAuthLoginParams(serverName: serverName, threadID: threadID)
        )
        return try Self.parseMCPOAuthLoginResponse(value)
    }

    func respond(to requestID: CodexRequestID, with response: CodexInteractionResponse) async throws {
        guard let pending = pendingInteractions[requestID] else {
            throw CodexClientError.invalidResponse("交互请求已失效或已响应")
        }
        let result = try Self.makeInteractionResponse(
            method: pending.method,
            request: pending.request,
            response: response
        )
        try respond(id: Self.wireValue(for: requestID), result: result)
        pendingInteractions.removeValue(forKey: requestID)
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

    func startThread(cwd: String, model: String?, serviceTier: String) async throws -> CodexStartedThread {
        try await ensureConnected()
        let params = Self.makeThreadStartParams(cwd: cwd, model: model, serviceTier: serviceTier)
        let value = try await request(method: "thread/start", params: params)
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
        let value = try await request(
            method: "thread/resume",
            params: Self.makeThreadResumeParams(threadID: threadID, cwd: cwd)
        )
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
        input: [CodexTurnInput],
        model: String,
        effort: ReasoningEffort,
        serviceTier: String
    ) async throws -> CodexStartedTurn {
        try await startTurn(
            threadID: threadID,
            cwd: cwd,
            input: input,
            model: model,
            effort: effort,
            serviceTier: serviceTier,
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
        input: [CodexTurnInput],
        model: String,
        effort: ReasoningEffort,
        serviceTier: String,
        allowNetwork: Bool
    ) async throws -> CodexStartedTurn {
        try await startTurn(
            threadID: threadID,
            cwd: cwd,
            input: input,
            model: model,
            effort: effort,
            serviceTier: serviceTier,
            mode: "default",
            sandboxPolicy: .object([
                "type": .string("workspaceWrite"),
                "writableRoots": .array([.string(cwd)]),
                "networkAccess": .bool(allowNetwork),
                "excludeTmpdirEnvVar": .bool(true),
                "excludeSlashTmp": .bool(true)
            ]),
            approvalPolicy: "on-request"
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
        input: [CodexTurnInput],
        model: String,
        effort: ReasoningEffort,
        serviceTier: String,
        mode: String,
        sandboxPolicy: JSONValue,
        approvalPolicy: String
    ) async throws -> CodexStartedTurn {
        let params = Self.makeTurnStartParams(
            threadID: threadID,
            cwd: cwd,
            input: input,
            model: model,
            effort: effort,
            serviceTier: serviceTier,
            mode: mode,
            sandboxPolicy: sandboxPolicy,
            approvalPolicy: approvalPolicy
        )
        let value = try await request(method: "turn/start", params: params)
        guard let turn = value["turn"],
              let turnID = turn["id"]?.stringValue,
              let status = turn["status"]?.stringValue
        else {
            throw CodexClientError.invalidResponse("turn/start 缺少 turn id/status")
        }
        return CodexStartedTurn(turnID: turnID, status: status)
    }

    static func makeThreadStartParams(cwd: String, model: String?, serviceTier: String?) -> JSONValue {
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
        if let serviceTier, !serviceTier.isEmpty { params["serviceTier"] = .string(serviceTier) }
        return .object(params)
    }

    static func makeThreadResumeParams(threadID: String, cwd: String) -> JSONValue {
        .object([
            "threadId": .string(threadID),
            "cwd": .string(cwd),
            "runtimeWorkspaceRoots": .array([.string(cwd)]),
            // CodexBoard persists its own task/run projections and never reads
            // thread.turns from this response. Excluding them also prevents a
            // long-running thread from becoming one enormous JSONL line.
            "excludeTurns": .bool(true)
        ])
    }

    static func makeInitializeParams(version: String) -> JSONValue {
        .object([
            "clientInfo": .object([
                "name": .string("codex_board"),
                "title": .string("CodexBoard"),
                "version": .string(version)
            ]),
            "capabilities": .object([
                "experimentalApi": .bool(true),
                "extensions": .object([
                    "openai/form": .object([:])
                ])
            ])
        ])
    }

    static func makeSkillsListParams(cwds: [String], forceReload: Bool) -> JSONValue {
        .object([
            "cwds": .array(cwds.map(JSONValue.string)),
            "forceReload": .bool(forceReload)
        ])
    }

    static func makeAppsListParams(
        cursor: String?,
        forceRefetch: Bool,
        threadID: String? = nil
    ) -> JSONValue {
        var params: [String: JSONValue] = ["limit": .integer(100)]
        if let cursor { params["cursor"] = .string(cursor) }
        if forceRefetch { params["forceRefetch"] = .bool(true) }
        if let threadID { params["threadId"] = .string(threadID) }
        return .object(params)
    }

    static func makeAppsInstalledParams(
        forceRefresh: Bool,
        threadID: String? = nil
    ) -> JSONValue {
        var params: [String: JSONValue] = ["forceRefresh": .bool(forceRefresh)]
        if let threadID { params["threadId"] = .string(threadID) }
        return .object(params)
    }

    static func makeAppsReadParams(appIDs: [String]) -> JSONValue {
        .object([
            "appIds": .array(appIDs.map(JSONValue.string)),
            "includeTools": .bool(true)
        ])
    }

    static func makeMCPServerListParams(cursor: String?, threadID: String?) -> JSONValue {
        var params: [String: JSONValue] = [
            "limit": .integer(100),
            "detail": .string("toolsAndAuthOnly")
        ]
        if let cursor { params["cursor"] = .string(cursor) }
        if let threadID { params["threadId"] = .string(threadID) }
        return .object(params)
    }

    static func makeMCPOAuthLoginParams(serverName: String, threadID: String?) -> JSONValue {
        var params: [String: JSONValue] = ["name": .string(serverName)]
        if let threadID { params["threadId"] = .string(threadID) }
        return .object(params)
    }

    static func appIDBatches(_ appIDs: [String]) -> [[String]] {
        stride(from: 0, to: appIDs.count, by: 100).map { start in
            Array(appIDs[start..<min(start + 100, appIDs.count)])
        }
    }

    static func makeTurnStartParams(
        threadID: String,
        cwd: String,
        input: [CodexTurnInput],
        model: String,
        effort: ReasoningEffort,
        serviceTier: String?,
        mode: String,
        sandboxPolicy: JSONValue,
        approvalPolicy: String
    ) -> JSONValue {
        var params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "input": .array(input.map(\.wireValue)),
            "cwd": .string(cwd),
            "effort": .string(effort.rawValue),
            "summary": .string("concise"),
            "personality": .string("pragmatic"),
            "approvalPolicy": .string(approvalPolicy),
            "approvalsReviewer": .string("user"),
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
        if let serviceTier, !serviceTier.isEmpty { params["serviceTier"] = .string(serviceTier) }
        return .object(params)
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

    private func respond(id: JSONValue, errorCode: Int64, message: String) throws {
        guard let transport else { throw CodexClientError.disconnected }
        try transport.send(try JSONEncoder().encode(Self.makeRPCErrorResponse(
            id: id,
            code: errorCode,
            message: message
        )))
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

    func handleServerRequest(id: JSONValue, method: String, params: JSONValue?) {
        do {
            switch method {
            case "currentTime/read":
                try respond(id: id, result: .object([
                    "currentTimeAt": .integer(Int64(Date().timeIntervalSince1970))
                ]))
            case "item/commandExecution/requestApproval",
                 "item/fileChange/requestApproval",
                 "item/tool/requestUserInput",
                 "item/permissions/requestApproval",
                 "mcpServer/elicitation/request":
                guard let request = Self.parseInteractionRequest(
                    id: id,
                    method: method,
                    params: params
                ) else {
                    try respond(id: id, errorCode: -32602, message: "Invalid interaction request params")
                    return
                }
                guard pendingInteractions[request.id] == nil else {
                    try respond(id: id, errorCode: -32600, message: "Duplicate interaction request id")
                    return
                }
                pendingInteractions[request.id] = PendingInteraction(method: method, request: request)
                eventContinuation?.yield(.interactionRequested(request))
            case "applyPatchApproval", "execCommandApproval":
                try respond(id: id, result: .object([
                    "decision": .object([
                        "denied": .object(["rejection": .string("CodexBoard does not grant sandbox escapes.")])
                    ])
                ]))
                emitWarning(params: params, message: "旧版 Codex 请求了沙箱外操作，已拒绝。")
            default:
                try respond(id: id, errorCode: -32601, message: "Method not found: \(method)")
                emitWarning(params: params, message: "未支持的 Codex 请求已拒绝：\(method)")
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func handleNotification(method: String, params: JSONValue?) {
        guard let params else { return }
        let threadID = params["threadId"]?.stringValue
        let turnID = params["turnId"]?.stringValue
        if method == "serverRequest/resolved",
           let threadID,
           let requestIDValue = params["requestId"],
           let requestID = Self.parseRequestID(requestIDValue) {
            pendingInteractions.removeValue(forKey: requestID)
            eventContinuation?.yield(.interactionResolved(threadID: threadID, requestID: requestID))
            return
        }
        if let completion = Self.parseMCPOAuthCompletion(method: method, params: params) {
            eventContinuation?.yield(.mcpOAuthCompleted(completion))
            return
        }
        if let event = Self.turnDiffEvent(method: method, params: params) {
            eventContinuation?.yield(event)
            return
        }
        if let event = Self.warningEvent(method: method, params: params) {
            eventContinuation?.yield(event)
            return
        }
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
        case "error":
            let message = Self.turnErrorDescription(params["error"]) ?? "Codex 执行错误"
            eventContinuation?.yield(.warning(threadID: threadID, turnID: turnID, message: message))
        default:
            break
        }
    }

    static func turnDiffEvent(method: String, params: JSONValue) -> CodexEvent? {
        guard method == "turn/diff/updated",
              let threadID = params["threadId"]?.stringValue,
              let turnID = params["turnId"]?.stringValue,
              let diff = params["diff"]?.stringValue
        else { return nil }
        return .turnDiffUpdated(threadID: threadID, turnID: turnID, diff: diff)
    }

    static func warningEvent(method: String, params: JSONValue) -> CodexEvent? {
        let threadID = params["threadId"]?.stringValue
        let turnID = params["turnId"]?.stringValue
        let message = params["message"]?.stringValue ?? method
        switch method {
        case "configWarning":
            return .configurationWarning(threadID: threadID, turnID: turnID, message: message)
        case "warning", "guardianWarning":
            return .warning(threadID: threadID, turnID: turnID, message: message)
        default:
            return nil
        }
    }

    private func emitWarning(params: JSONValue?, message: String) {
        eventContinuation?.yield(.warning(
            threadID: params?["threadId"]?.stringValue,
            turnID: params?["turnId"]?.stringValue,
            message: message
        ))
    }

    static func parseRequestID(_ value: JSONValue) -> CodexRequestID? {
        switch value {
        case let .string(id): .string(id)
        case let .integer(id): .integer(id)
        default: nil
        }
    }

    static func wireValue(for requestID: CodexRequestID) -> JSONValue {
        switch requestID {
        case let .string(id): .string(id)
        case let .integer(id): .integer(id)
        }
    }

    static func makeRPCErrorResponse(id: JSONValue, code: Int64, message: String) -> JSONValue {
        .object([
            "id": id,
            "error": .object([
                "code": .integer(code),
                "message": .string(message)
            ])
        ])
    }

    static func parseInteractionRequest(
        id: JSONValue,
        method: String,
        params: JSONValue?,
        receivedAt: Date = Date()
    ) -> CodexInteractionRequest? {
        guard let requestID = parseRequestID(id),
              let params,
              let threadID = params["threadId"]?.stringValue
        else { return nil }

        let turnID = params["turnId"]?.stringValue
        let itemID = params["itemId"]?.stringValue
        let createdAt = interactionCreatedAt(params: params, fallback: receivedAt)
        let kind: CodexInteractionRequest.Kind

        switch method {
        case "item/commandExecution/requestApproval":
            guard turnID != nil,
                  itemID != nil,
                  case .integer? = params["startedAtMs"]
            else { return nil }
            let availableDecisions: [CodexApprovalDecision]?
            if let values = params["availableDecisions"]?.arrayValue {
                availableDecisions = values.compactMap { value in
                    value.stringValue.flatMap { CodexApprovalDecision(rawValue: $0) }
                }
            } else {
                availableDecisions = nil
            }
            kind = .commandApproval(CodexCommandApproval(
                command: params["command"]?.stringValue,
                cwd: params["cwd"]?.stringValue,
                reason: params["reason"]?.stringValue,
                commandActions: params["commandActions"],
                requestedPermissions: params["additionalPermissions"],
                availableDecisions: availableDecisions
            ))
        case "item/fileChange/requestApproval":
            guard turnID != nil,
                  itemID != nil,
                  case .integer? = params["startedAtMs"]
            else { return nil }
            kind = .fileChangeApproval(CodexFileChangeApproval(
                reason: params["reason"]?.stringValue,
                grantRoot: params["grantRoot"]?.stringValue
            ))
        case "item/tool/requestUserInput":
            guard turnID != nil,
                  itemID != nil,
                  let isBlocking = params["isBlocking"]?.boolValue,
                  let questionValues = params["questions"]?.arrayValue,
                  (1...3).contains(questionValues.count)
            else { return nil }
            let questions = questionValues.compactMap(Self.parseUserInputQuestion)
            guard questions.count == questionValues.count,
                  Set(questions.map(\.id)).count == questions.count
            else { return nil }
            kind = .userInput(CodexUserInputRequest(
                questions: questions,
                isBlocking: isBlocking
            ))
        case "item/permissions/requestApproval":
            guard turnID != nil,
                  itemID != nil,
                  case .integer? = params["startedAtMs"],
                  let cwd = params["cwd"]?.stringValue,
                  let permissions = params["permissions"],
                  permissions.objectValue != nil
            else { return nil }
            kind = .permissionsApproval(CodexPermissionsApproval(
                cwd: cwd,
                reason: params["reason"]?.stringValue,
                permissions: permissions
            ))
        case "mcpServer/elicitation/request":
            guard let serverName = params["serverName"]?.stringValue,
                  let rawMode = params["mode"]?.stringValue,
                  let mode = CodexMCPElicitationMode(rawValue: rawMode),
                  let message = params["message"]?.stringValue
            else { return nil }
            let url: URL?
            switch mode {
            case .form, .openAIForm:
                guard params["requestedSchema"] != nil else { return nil }
                url = nil
            case .url:
                guard params["elicitationId"]?.stringValue != nil,
                      let rawURL = params["url"]?.stringValue,
                      let safeURL = safeHTTPURL(rawURL)
                else { return nil }
                url = safeURL
            }
            kind = .mcpElicitation(CodexMCPElicitation(
                serverName: serverName,
                mode: mode,
                message: message,
                requestedSchema: params["requestedSchema"],
                url: url,
                elicitationID: params["elicitationId"]?.stringValue,
                metadata: params["_meta"]
            ))
        default:
            return nil
        }

        return CodexInteractionRequest(
            id: requestID,
            threadID: threadID,
            turnID: turnID,
            itemID: itemID,
            kind: kind,
            createdAt: createdAt
        )
    }

    static func parseUserInputQuestion(_ value: JSONValue) -> CodexUserInputQuestion? {
        guard let id = value["id"]?.stringValue,
              let header = value["header"]?.stringValue,
              let question = value["question"]?.stringValue
        else { return nil }

        let options: [CodexUserInputOption]?
        if let values = value["options"]?.arrayValue {
            let parsed = values.compactMap { option -> CodexUserInputOption? in
                guard let label = option["label"]?.stringValue,
                      let description = option["description"]?.stringValue
                else { return nil }
                return CodexUserInputOption(label: label, description: description)
            }
            guard parsed.count == values.count else { return nil }
            options = parsed
        } else {
            options = nil
        }

        return CodexUserInputQuestion(
            id: id,
            header: header,
            question: question,
            isOther: value["isOther"]?.boolValue ?? false,
            isSecret: value["isSecret"]?.boolValue ?? false,
            options: options
        )
    }

    static func makeInteractionResponse(
        method: String,
        request: CodexInteractionRequest,
        response: CodexInteractionResponse
    ) throws -> JSONValue {
        guard method == interactionMethod(for: request.kind) else {
            throw CodexClientError.invalidResponse("交互请求 method 与类型不匹配")
        }

        switch (request.kind, response) {
        case let (.commandApproval(approval), .approval(decision)):
            if let available = approval.availableDecisions, !available.contains(decision) {
                throw CodexClientError.invalidResponse("命令审批 decision 不在服务端允许范围内")
            }
            return .object(["decision": .string(decision.rawValue)])
        case (.fileChangeApproval, let .approval(decision)):
            return .object(["decision": .string(decision.rawValue)])
        case let (.userInput(input), .userInput(answers)):
            let expectedIDs = Set(input.questions.map(\.id))
            guard Set(answers.keys) == expectedIDs else {
                throw CodexClientError.invalidResponse("用户输入答案与 question id 不匹配")
            }
            return .object([
                "answers": .object(answers.mapValues { values in
                    .object(["answers": .array(values.map(JSONValue.string))])
                })
            ])
        case let (.permissionsApproval(approval), .permissions(decision)):
            switch decision {
            case let .deny(scope):
                return .object([
                    "permissions": .object([:]),
                    "scope": .string(scope.rawValue)
                ])
            case let .grant(permissions, scope):
                guard permissions.objectValue != nil,
                      permissions == approval.permissions
                else {
                    throw CodexClientError.invalidResponse("permissions grant 必须精确匹配服务端请求")
                }
                return .object([
                    "permissions": permissions,
                    "scope": .string(scope.rawValue)
                ])
            }
        case let (.mcpElicitation(elicitation), .mcpElicitation(elicitationResponse)):
            switch (elicitation.mode, elicitationResponse) {
            case let (.form, .accept(content, metadata)),
                 let (.openAIForm, .accept(content, metadata)):
                guard content.objectValue != nil else {
                    throw CodexClientError.invalidResponse("MCP 表单响应必须是 JSON object")
                }
                var result: [String: JSONValue] = [
                    "action": .string("accept"),
                    "content": content
                ]
                if let metadata { result["_meta"] = metadata }
                return .object(result)
            case (.url, .acceptURL):
                return .object(["action": .string("accept")])
            case (_, .decline):
                return .object(["action": .string("decline")])
            case (_, .cancel):
                return .object(["action": .string("cancel")])
            case (.url, .accept), (.form, .acceptURL), (.openAIForm, .acceptURL):
                throw CodexClientError.invalidResponse("MCP 响应类型与 elicitation mode 不匹配")
            }
        default:
            throw CodexClientError.invalidResponse("响应类型与交互请求不匹配")
        }
    }

    static func interactionMethod(for kind: CodexInteractionRequest.Kind) -> String {
        switch kind {
        case .commandApproval: "item/commandExecution/requestApproval"
        case .fileChangeApproval: "item/fileChange/requestApproval"
        case .userInput: "item/tool/requestUserInput"
        case .permissionsApproval: "item/permissions/requestApproval"
        case .mcpElicitation: "mcpServer/elicitation/request"
        }
    }

    static func parseMCPServerListResponse(_ value: JSONValue) throws -> MCPServerPage {
        guard let data = value["data"]?.arrayValue else {
            throw CodexClientError.invalidResponse("mcpServerStatus/list 缺少 data")
        }
        return MCPServerPage(
            servers: data.compactMap(Self.parseMCPServerStatus),
            nextCursor: value["nextCursor"]?.stringValue
        )
    }

    static func parseMCPServerStatus(_ value: JSONValue) -> CodexMCPServerStatus? {
        guard let name = value["name"]?.stringValue else { return nil }
        let serverInfo = value["serverInfo"]
        return CodexMCPServerStatus(
            name: name,
            authStatus: value["authStatus"]?.stringValue ?? "unknown",
            title: serverInfo?["title"]?.stringValue,
            description: serverInfo?["description"]?.stringValue,
            version: serverInfo?["version"]?.stringValue,
            websiteURL: serverInfo?["websiteUrl"]?.stringValue.flatMap { safeHTTPURL($0) },
            toolNames: value["tools"]?.objectValue?.keys.sorted() ?? []
        )
    }

    static func parseMCPOAuthLoginResponse(_ value: JSONValue) throws -> URL {
        guard let rawURL = value["authorizationUrl"]?.stringValue,
              let url = safeHTTPURL(rawURL)
        else {
            throw CodexClientError.invalidResponse("mcpServer/oauth/login 返回了非 HTTP(S) URL")
        }
        return url
    }

    static func parseMCPOAuthCompletion(method: String, params: JSONValue) -> CodexMCPOAuthCompletion? {
        guard method == mcpOAuthCompletionMethod,
              let serverName = params["name"]?.stringValue,
              let success = params["success"]?.boolValue
        else { return nil }
        return CodexMCPOAuthCompletion(
            serverName: serverName,
            threadID: params["threadId"]?.stringValue,
            success: success,
            error: params["error"]?.stringValue
        )
    }

    private static func interactionCreatedAt(params: JSONValue, fallback: Date) -> Date {
        guard case let .integer(milliseconds)? = params["startedAtMs"] else { return fallback }
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }

    private static func safeHTTPURL(_ rawValue: String) -> URL? {
        guard let url = URL(string: rawValue),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return url
    }

    static func parseSkillsListResponse(_ value: JSONValue) throws -> [String: [CodexSkillMetadata]] {
        guard let entries = value["data"]?.arrayValue else {
            throw CodexClientError.invalidResponse("skills/list 缺少 data")
        }

        var result: [String: [CodexSkillMetadata]] = [:]
        for entry in entries {
            guard let cwd = entry["cwd"]?.stringValue else { continue }
            let skills = entry["skills"]?.arrayValue?.compactMap(Self.parseSkillMetadata) ?? []
            result[cwd, default: []].append(contentsOf: skills)
        }
        return result
    }

    static func parseSkillMetadata(_ value: JSONValue) -> CodexSkillMetadata? {
        guard let name = value["name"]?.stringValue,
              let path = value["path"]?.stringValue
        else { return nil }

        return CodexSkillMetadata(
            name: name,
            description: value["description"]?.stringValue ?? "",
            shortDescription: value["interface"]?["shortDescription"]?.stringValue
                ?? value["shortDescription"]?.stringValue,
            path: path,
            scope: value["scope"]?.stringValue ?? "unknown",
            enabled: value["enabled"]?.boolValue ?? false
        )
    }

    static func parseAppListResponse(_ value: JSONValue) throws -> AppListPage {
        guard let data = value["data"]?.arrayValue else {
            throw CodexClientError.invalidResponse("app/list 缺少 data")
        }
        return AppListPage(
            apps: data.compactMap(Self.parseAppInfo),
            nextCursor: value["nextCursor"]?.stringValue
        )
    }

    static func parseAppInfo(_ value: JSONValue) -> ParsedAppInfo? {
        guard let id = value["id"]?.stringValue,
              let name = value["name"]?.stringValue
        else { return nil }

        return ParsedAppInfo(
            id: id,
            name: name,
            description: value["description"]?.stringValue,
            isAccessible: value["isAccessible"]?.boolValue ?? false,
            isEnabled: value["isEnabled"]?.boolValue ?? true
        )
    }

    static func parseAppsInstalledResponse(_ value: JSONValue) throws -> [ParsedInstalledApp] {
        guard let apps = value["apps"]?.arrayValue else {
            throw CodexClientError.invalidResponse("app/installed 缺少 apps")
        }
        return apps.compactMap(Self.parseInstalledApp)
    }

    static func parseInstalledApp(_ value: JSONValue) -> ParsedInstalledApp? {
        guard let id = value["id"]?.stringValue else { return nil }
        return ParsedInstalledApp(
            id: id,
            isEnabled: value["enabled"]?.boolValue ?? false,
            isCallable: value["callable"]?.boolValue ?? false,
            runtimeName: value["runtimeName"]?.stringValue
        )
    }

    static func parseAppsReadResponse(_ value: JSONValue) throws -> [ParsedConnectorMetadata] {
        guard let apps = value["apps"]?.arrayValue else {
            throw CodexClientError.invalidResponse("app/read 缺少 apps")
        }
        return apps.compactMap(Self.parseConnectorMetadata)
    }

    static func parseConnectorMetadata(_ value: JSONValue) -> ParsedConnectorMetadata? {
        guard let id = value["id"]?.stringValue else { return nil }
        let tools = value["toolSummaries"]?.arrayValue?.compactMap(Self.parseAppToolSummary) ?? []
        return ParsedConnectorMetadata(
            id: id,
            name: value["name"]?.stringValue,
            description: value["description"]?.stringValue,
            tools: tools
        )
    }

    static func parseAppToolSummary(_ value: JSONValue) -> CodexAppToolSummary? {
        guard let name = value["name"]?.stringValue else { return nil }
        return CodexAppToolSummary(
            name: name,
            title: value["title"]?.stringValue,
            description: value["description"]?.stringValue ?? "",
            isEnabled: value["isEnabled"]?.boolValue ?? true,
            isReadOnly: value["isReadOnly"]?.boolValue ?? false,
            disabledReason: value["disabledReason"]?.stringValue
        )
    }

    static func mergeApps(
        listed: [ParsedAppInfo],
        installed: [ParsedInstalledApp],
        metadata: [ParsedConnectorMetadata]
    ) -> [CodexApp] {
        let installedByID = Dictionary(
            installed.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let metadataByID = Dictionary(
            metadata.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        var seenAppIDs: Set<String> = []

        return listed.compactMap { app in
            guard app.isAccessible, seenAppIDs.insert(app.id).inserted else { return nil }
            let runtime = installedByID[app.id]
            let connector = metadataByID[app.id]
            let canonicalName = nonEmpty(connector?.name) ?? app.name
            let invocationName = nonEmpty(runtime?.runtimeName) ?? canonicalName
            return CodexApp(
                id: app.id,
                name: canonicalName,
                invocationName: invocationName,
                description: nonEmpty(connector?.description) ?? app.description ?? "",
                isAccessible: app.isAccessible,
                isEnabled: runtime?.isEnabled ?? app.isEnabled,
                isCallable: runtime?.isCallable ?? false,
                tools: connector?.tools ?? []
            )
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    static func parseModel(_ value: JSONValue) -> CodexModel? {
        guard let id = value["id"]?.stringValue,
              let model = value["model"]?.stringValue,
              let displayName = value["displayName"]?.stringValue,
              let description = value["description"]?.stringValue,
              let isDefault = value["isDefault"]?.boolValue,
              let defaultEffort = value["defaultReasoningEffort"]?.stringValue
        else { return nil }

        let supportedReasoningEfforts: [CodexReasoningEffortOption] = value["supportedReasoningEfforts"]?.arrayValue?.compactMap { option in
            guard let effort = option["reasoningEffort"]?.stringValue,
                  let description = option["description"]?.stringValue
            else { return nil }
            return CodexReasoningEffortOption(
                effort: ReasoningEffort(rawValue: effort),
                description: description
            )
        } ?? []
        var serviceTiers: [CodexModelServiceTier] = value["serviceTiers"]?.arrayValue?.compactMap { tier in
            guard let id = tier["id"]?.stringValue,
                  let name = tier["name"]?.stringValue,
                  let description = tier["description"]?.stringValue
            else { return nil }
            return CodexModelServiceTier(id: id, name: name, description: description)
        } ?? []
        let legacySpeedTiers = value["additionalSpeedTiers"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if legacySpeedTiers.contains("fast"),
           !serviceTiers.contains(where: { $0.id == CodexServiceTier.fast }) {
            serviceTiers.append(CodexModelServiceTier(
                id: CodexServiceTier.fast,
                name: "Fast",
                description: "Faster responses"
            ))
        }

        return CodexModel(
            id: id,
            model: model,
            displayName: displayName,
            description: description,
            isDefault: isDefault,
            defaultReasoningEffort: ReasoningEffort(rawValue: defaultEffort),
            supportedReasoningEfforts: supportedReasoningEfforts,
            serviceTiers: serviceTiers
        )
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
        pendingInteractions.removeAll()
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
