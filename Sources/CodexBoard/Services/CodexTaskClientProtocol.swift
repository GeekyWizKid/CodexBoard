import Foundation

@MainActor
protocol CodexTaskClient: AnyObject {
    var events: AsyncStream<CodexEvent> { get }
    var connectionState: CodexConnectionState { get }

    func connect() async throws
    func verifyAccount() async throws -> Bool
    func listThreads(cursor: String?, archived: Bool) async throws -> CodexThreadPage
    func startThread(cwd: String, model: String?) async throws -> CodexStartedThread
    func resumeThread(threadID: String, cwd: String) async throws -> CodexStartedThread
    func setThreadName(threadID: String, name: String) async throws
    func startPlanningTurn(
        threadID: String,
        cwd: String,
        prompt: String,
        model: String,
        effort: ReasoningEffort
    ) async throws -> CodexStartedTurn
    func startExecutionTurn(
        threadID: String,
        cwd: String,
        prompt: String,
        model: String,
        effort: ReasoningEffort,
        allowNetwork: Bool
    ) async throws -> CodexStartedTurn
    func interrupt(threadID: String, turnID: String) async throws
}

extension CodexAppServerClient: CodexTaskClient {}
