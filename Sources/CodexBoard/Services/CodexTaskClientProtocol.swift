import Foundation

@MainActor
protocol CodexTaskClient: AnyObject {
    var events: AsyncStream<CodexEvent> { get }
    var connectionState: CodexConnectionState { get }

    func connect() async throws
    func verifyAccount() async throws -> Bool
    func listModels() async throws -> [CodexModel]
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

extension CodexAppServerClient: CodexTaskClient {}
