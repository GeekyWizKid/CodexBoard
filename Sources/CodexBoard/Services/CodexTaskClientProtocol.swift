import Foundation

@MainActor
protocol CodexTaskClient: AnyObject {
    var events: AsyncStream<CodexEvent> { get }
    var connectionState: CodexConnectionState { get }

    func connect() async throws
    func disconnect()
    func verifyAccount() async throws -> Bool
    func listThreads(cursor: String?, archived: Bool) async throws -> CodexThreadPage
    func inspectProjectPath(_ path: String) async throws -> CodexProjectPathInfo
    func readThread(threadID: String, includeTurns: Bool) async throws -> CodexThreadDetail
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

extension CodexTaskClient {
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
