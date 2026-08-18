import Foundation

@MainActor
protocol CodexTaskClient: AnyObject {
    var events: AsyncStream<CodexEvent> { get }
    var connectionState: CodexConnectionState { get }

    func connect() async throws
    func disconnect()
    func verifyAccount() async throws -> Bool
    func listModels() async throws -> [CodexModel]
    func listSkills(cwds: [String], forceReload: Bool) async throws -> [String: [CodexSkillMetadata]]
    func listApps(forceRefresh: Bool) async throws -> [CodexApp]
    func listApps(forceRefresh: Bool, threadID: String?) async throws -> [CodexApp]
    func listMCPServers(threadID: String?) async throws -> [CodexMCPServerStatus]
    func beginMCPOAuth(serverName: String, threadID: String?) async throws -> URL
    func respond(to requestID: CodexRequestID, with response: CodexInteractionResponse) async throws
    func listThreads(cursor: String?, archived: Bool) async throws -> CodexThreadPage
    func inspectProjectPath(_ path: String) async throws -> CodexProjectPathInfo
    func readThread(threadID: String, includeTurns: Bool) async throws -> CodexThreadDetail
    func startThread(cwd: String, model: String?, serviceTier: String) async throws -> CodexStartedThread
    func resumeThread(threadID: String, cwd: String) async throws -> CodexStartedThread
    func setThreadName(threadID: String, name: String) async throws
    func startPlanningTurn(
        threadID: String,
        cwd: String,
        input: [CodexTurnInput],
        model: String,
        effort: ReasoningEffort,
        serviceTier: String
    ) async throws -> CodexStartedTurn
    func startExecutionTurn(
        threadID: String,
        cwd: String,
        input: [CodexTurnInput],
        model: String,
        effort: ReasoningEffort,
        serviceTier: String,
        allowNetwork: Bool
    ) async throws -> CodexStartedTurn
    func interrupt(threadID: String, turnID: String) async throws
}

extension CodexTaskClient {
    func listApps(forceRefresh: Bool, threadID: String?) async throws -> [CodexApp] {
        try await listApps(forceRefresh: forceRefresh)
    }

    func disconnect() {}

    func inspectProjectPath(_ path: String) async throws -> CodexProjectPathInfo {
        CodexProjectPathInfo(
            canonicalWorkingDirectory: path,
            projectPath: path,
            exists: true,
            isGitRepository: false
        )
    }

    func readThread(threadID: String, includeTurns: Bool) async throws -> CodexThreadDetail {
        throw CodexClientError.invalidResponse("当前 Codex 客户端不支持 thread/read")
    }
}

extension CodexAppServerClient: CodexTaskClient {}

typealias CodexDynamicToolHandler = @MainActor @Sendable (CodexDynamicToolCall) async -> CodexDynamicToolResult

@MainActor
protocol CodexRealtimeClient: AnyObject {
    var realtimeEvents: AsyncStream<CodexRealtimeEvent> { get }
    var connectionState: CodexConnectionState { get }

    func connect() async throws
    func disconnect()
    func startLiveThread(
        cwd: String,
        model: String?,
        tools: [CodexDynamicToolSpec]
    ) async throws -> CodexStartedThread
    func listRealtimeVoices() async throws -> CodexRealtimeVoiceCatalog
    func startRealtime(threadID: String, options: CodexRealtimeStartOptions) async throws
    func appendRealtimeAudio(threadID: String, chunk: CodexRealtimeAudioChunk) async throws
    func appendRealtimeText(threadID: String, text: String, role: CodexRealtimeTextRole) async throws
    func appendRealtimeSpeech(threadID: String, text: String) async throws
    func stopRealtime(threadID: String) async throws
    @discardableResult
    func registerDynamicToolHandler(
        threadID: String,
        tool: String,
        handler: @escaping CodexDynamicToolHandler
    ) -> UUID
    func unregisterDynamicToolHandler(_ registrationID: UUID)
}

extension CodexAppServerClient: CodexRealtimeClient {}
