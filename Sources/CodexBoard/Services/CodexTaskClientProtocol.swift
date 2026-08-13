import Foundation

@MainActor
protocol CodexTaskClient: AnyObject {
    var events: AsyncStream<CodexEvent> { get }
    var connectionState: CodexConnectionState { get }

    func connect() async throws
    func verifyAccount() async throws -> Bool
    func listModels() async throws -> [CodexModel]
    func listSkills(cwds: [String], forceReload: Bool) async throws -> [String: [CodexSkillMetadata]]
    func listApps(forceRefresh: Bool) async throws -> [CodexApp]
    func listApps(forceRefresh: Bool, threadID: String?) async throws -> [CodexApp]
    func listMCPServers(threadID: String?) async throws -> [CodexMCPServerStatus]
    func beginMCPOAuth(serverName: String, threadID: String?) async throws -> URL
    func respond(to requestID: CodexRequestID, with response: CodexInteractionResponse) async throws
    func listThreads(cursor: String?, archived: Bool) async throws -> CodexThreadPage
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
}

extension CodexAppServerClient: CodexTaskClient {}
