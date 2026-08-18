import Foundation
import XCTest
@testable import CodexBoard

@MainActor
final class LiveTaskComposerStoreTests: XCTestCase {
    func testStartUsesFrozenProjectAndWaitsForStartedBeforeSavingCredential() async throws {
        let fixture = try Fixture(storedAPIKey: " sk-stored ")
        defer { fixture.cleanup() }

        XCTAssertEqual(fixture.store.apiKey, " sk-stored ")
        XCTAssertTrue(fixture.store.hasStoredAPIKey)

        await fixture.store.start()

        XCTAssertEqual(fixture.factory.apiKeys, ["sk-stored"])
        XCTAssertEqual(fixture.store.state, .startingRealtime)
        XCTAssertEqual(fixture.client.liveThreadCWD, fixture.workspace.path)
        XCTAssertNotEqual(fixture.client.liveThreadCWD, fixture.store.projectID)
        XCTAssertEqual(fixture.client.liveTools.map(\.name), [LiveTaskDraftDecoder.toolName])
        XCTAssertEqual(fixture.client.realtimeThreadID, "live-thread")
        let realtimePrompt = try XCTUnwrap(fixture.client.realtimeOptions?.prompt)
        XCTAssertTrue(realtimePrompt.contains(fixture.store.projectReference))
        XCTAssertTrue(realtimePrompt.contains("这是只读需求采集会话"))
        XCTAssertTrue(realtimePrompt.contains("不运行命令、不读取文件、不请求额外权限"))
        XCTAssertEqual(fixture.credentials.savedValues, [])

        fixture.client.send(.started(threadID: "other-thread", version: .v2, sessionID: nil))
        await Task.yield()
        XCTAssertEqual(fixture.store.state, .startingRealtime)

        fixture.client.send(.started(threadID: "live-thread", version: .v2, sessionID: "rt-1"))
        try await eventually { fixture.store.state == .live }
        XCTAssertEqual(fixture.credentials.savedValues, [])
        fixture.client.send(.transcriptDelta(threadID: "live-thread", role: "assistant", delta: "你好"))
        try await eventually { fixture.credentials.savedValues == ["sk-stored"] }
    }

    func testStartedThenAuthenticationErrorNeverSavesCredential() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.store.apiKey = "sk-invalid"

        await fixture.store.start()
        fixture.client.send(.started(threadID: "live-thread", version: .v2, sessionID: nil))
        fixture.client.send(.error(threadID: "live-thread", message: "Incorrect API key"))

        try await eventually {
            fixture.store.state == .failed(message: "Incorrect API key")
        }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(fixture.credentials.savedValues, [])
        XCTAssertTrue(fixture.client.didDisconnect)
    }

    func testRememberOffDoesNotSaveAfterStarted() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.store.apiKey = "sk-session-only"
        fixture.store.rememberAPIKey = false

        await fixture.store.start()
        fixture.client.send(.started(threadID: "live-thread", version: .v2, sessionID: nil))
        try await eventually { fixture.store.state == .live }
        fixture.client.send(.transcriptDelta(threadID: "live-thread", role: "assistant", delta: "valid"))
        await Task.yield()

        XCTAssertEqual(fixture.credentials.savedValues, [])
    }

    func testDynamicToolStrictlyDecodesAndDeduplicatesDraftBatch() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.startLive()

        let call = fixture.toolCall(
            callID: "call-1",
            tasks: [
                (" First ", .issue, " Do the first thing "),
                ("Second", .developmentPlan, "Plan the second thing")
            ]
        )
        let firstResult = await fixture.client.invokeRegisteredTool(call)

        XCTAssertTrue(firstResult.success)
        XCTAssertEqual(fixture.store.state, .reviewing)
        XCTAssertEqual(fixture.store.drafts.map(\.title), ["First", "Second"])
        XCTAssertEqual(fixture.store.drafts.map(\.projectID), ["frozen-project", "frozen-project"])
        let originalDraftIDs = fixture.store.drafts.map(\.id)

        let duplicateWithDifferentArguments = fixture.toolCall(
            callID: "call-1",
            tasks: [("Should not replace", .issue, "Different")]
        )
        let duplicateResult = await fixture.client.invokeRegisteredTool(duplicateWithDifferentArguments)

        XCTAssertEqual(duplicateResult, firstResult)
        XCTAssertEqual(fixture.store.drafts.map(\.id), originalDraftIDs)
        XCTAssertEqual(fixture.store.drafts.map(\.title), ["First", "Second"])
    }

    func testDynamicToolRejectsUnknownTopLevelField() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.startLive()
        var arguments = fixture.toolArguments(tasks: [("Task", .issue, "Body")]).objectValue!
        arguments["unexpected"] = .bool(true)
        let call = CodexDynamicToolCall(
            threadID: "live-thread",
            turnID: "turn-1",
            callID: "bad-call",
            namespace: nil,
            tool: LiveTaskDraftDecoder.toolName,
            arguments: .object(arguments)
        )

        let result = await fixture.client.invokeRegisteredTool(call)

        XCTAssertFalse(result.success)
        XCTAssertTrue(fixture.store.drafts.isEmpty)
    }

    func testEditedDraftValidationAndConfirmationAreIdempotentAndNeverAutoRun() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.startLive()
        _ = await fixture.client.invokeRegisteredTool(
            fixture.toolCall(callID: "call-1", tasks: [("Task", .issue, "Body")])
        )
        var draft = try XCTUnwrap(fixture.store.drafts.first)
        draft.title = "   "
        fixture.store.updateDraft(draft)

        XCTAssertNil(fixture.store.confirmDraft(id: draft.id))
        XCTAssertTrue(fixture.store.lastError?.contains("草稿不完整") == true)
        XCTAssertEqual(fixture.creations.requests.count, 0)

        draft.title = " Edited title "
        draft.sourceText = " Edited body "
        fixture.store.updateDraft(draft)
        let firstTaskID = try XCTUnwrap(fixture.store.confirmDraft(id: draft.id))
        let duplicateTaskID = fixture.store.confirmDraft(id: draft.id)

        XCTAssertEqual(duplicateTaskID, firstTaskID)
        XCTAssertEqual(fixture.creations.requests.count, 1)
        let request = try XCTUnwrap(fixture.creations.requests.first)
        XCTAssertEqual(request.projectID, "frozen-project")
        XCTAssertEqual(request.title, "Edited title")
        XCTAssertEqual(request.sourceText, "Edited body")
        XCTAssertEqual(request.sourceKind, .issue)
        XCTAssertFalse(request.autoRun)
        XCTAssertEqual(fixture.store.createdTaskIDs, [firstTaskID])
    }

    func testCancelDiscardsDraftsWithoutCreatingTask() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.startLive()
        _ = await fixture.client.invokeRegisteredTool(
            fixture.toolCall(callID: "call-1", tasks: [("Task", .issue, "Body")])
        )

        await fixture.store.cancel()

        XCTAssertEqual(fixture.store.state, .closed(reason: nil))
        XCTAssertTrue(fixture.store.drafts.isEmpty)
        XCTAssertTrue(fixture.creations.requests.isEmpty)
        XCTAssertTrue(fixture.client.didStopRealtime)
    }

    func testDraftRequestTimeoutReturnsToLiveAndAllowsRetry() async throws {
        let fixture = try Fixture(draftRequestTimeout: 0.03)
        defer { fixture.cleanup() }
        try await fixture.startLive()

        await fixture.store.requestDrafts()

        XCTAssertEqual(fixture.store.state, .requestingDrafts)
        XCTAssertTrue(fixture.client.appendedTexts.last?.contains(LiveTaskDraftDecoder.toolName) == true)
        try await eventually { fixture.store.state == .live }
        XCTAssertEqual(fixture.store.lastError, "未收到草稿，可补充需求后重试")
    }

    func testAudioUploadIsOrderedBoundedAndMicStopAppendsFourHundredMillisecondsSilence() async throws {
        let gate = AsyncGate()
        let fixture = try Fixture(maxPendingAudioChunks: 2, audioAppendGate: gate)
        defer { fixture.cleanup() }
        try await fixture.startLive()

        await fixture.store.setMicrophoneEnabled(true)
        XCTAssertTrue(fixture.store.isMicrophoneEnabled)

        await fixture.audio.emit(try audioBuffer(sample: 0.1))
        try await eventually { fixture.client.audioAppendStarted == 1 }
        await fixture.audio.emit(try audioBuffer(sample: 0.2))
        await fixture.audio.emit(try audioBuffer(sample: 0.3))
        await fixture.audio.emit(try audioBuffer(sample: 0.4))
        await fixture.audio.emit(try audioBuffer(sample: 0.5))
        try await eventually { fixture.store.droppedAudioChunkCount == 2 }

        await gate.open()
        await fixture.store.setMicrophoneEnabled(false)

        XCTAssertFalse(fixture.store.isMicrophoneEnabled)
        XCTAssertEqual(fixture.client.appendedAudio.count, 4)
        let silence = try XCTUnwrap(fixture.client.appendedAudio.last)
        XCTAssertEqual(silence.sampleRate, 24_000)
        XCTAssertEqual(silence.channelCount, 1)
        XCTAssertEqual(silence.samplesPerChannel, 9_600)
        XCTAssertTrue(silence.data.allSatisfy { $0 == 0 })
        XCTAssertEqual(fixture.client.maximumConcurrentAudioAppends, 1)
    }

    func testTranscriptAndOutputAudioEventsAreFilteredByThread() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.startLive()
        let output = try CodexRealtimeAudioChunk(
            data: Data(repeating: 0, count: 16),
            sampleRate: 24_000,
            channelCount: 1,
            samplesPerChannel: 8
        )

        fixture.client.send(.transcriptDone(threadID: "other", role: "user", text: "Ignore"))
        fixture.client.send(.transcriptDelta(threadID: "live-thread", role: "user", delta: "你好"))
        fixture.client.send(.transcriptDone(threadID: "live-thread", role: "user", text: "你好，Codex"))
        fixture.client.send(.outputAudioDelta(threadID: "live-thread", chunk: output))

        try await eventually { fixture.store.transcript.count == 1 }
        XCTAssertEqual(fixture.store.transcript.first?.text, "你好，Codex")
        XCTAssertEqual(fixture.store.liveTranscript, "")
        try await eventually { await fixture.audio.playedCount() == 1 }
    }

    private func audioBuffer(sample: Float) throws -> RealtimeAudioBuffer {
        let samples = [Float](repeating: sample, count: 240)
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        return try RealtimeAudioBuffer(
            data: data,
            sampleRate: 24_000,
            channelCount: 1,
            frameCount: 240
        )
    }

    private func eventually(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition was not met before timeout")
    }
}

@MainActor
private struct Fixture {
    let workspace: URL
    let credentials: FakeCredentialStore
    let client: MockRealtimeClient
    let factory: ClientFactoryRecorder
    let audio: FakeLiveAudioService
    let creations: TaskCreationRecorder
    let store: LiveTaskComposerStore

    init(
        storedAPIKey: String? = nil,
        draftRequestTimeout: TimeInterval = 20,
        maxPendingAudioChunks: Int = 8,
        audioAppendGate: AsyncGate? = nil
    ) throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveTaskComposerStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        credentials = FakeCredentialStore(storedValue: storedAPIKey)
        client = MockRealtimeClient(audioAppendGate: audioAppendGate)
        factory = ClientFactoryRecorder(client: client)
        audio = FakeLiveAudioService()
        creations = TaskCreationRecorder()
        store = LiveTaskComposerStore(
            projectID: "frozen-project",
            projectName: "Frozen Project",
            credentialStore: credentials,
            clientFactory: { [factory] apiKey in factory.make(apiKey: apiKey) },
            audioService: audio,
            workspaceProvider: { [workspace] in workspace },
            maxPendingAudioChunks: maxPendingAudioChunks,
            realtimeStartTimeout: 1,
            draftRequestTimeout: draftRequestTimeout,
            createTask: { [creations] projectID, title, sourceKind, sourceText, autoRun in
                creations.create(
                    projectID: projectID,
                    title: title,
                    sourceKind: sourceKind,
                    sourceText: sourceText,
                    autoRun: autoRun
                )
            }
        )
        if storedAPIKey == nil {
            store.apiKey = "sk-test"
        }
    }

    func startLive() async throws {
        await store.start()
        client.send(.started(threadID: "live-thread", version: .v2, sessionID: "rt-1"))
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if store.state == .live { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Live session did not start")
    }

    func toolArguments(
        tasks: [(String, TaskSourceKind, String)]
    ) -> JSONValue {
        .object([
            "projectRef": .string(store.projectReference),
            "tasks": .array(tasks.map { title, kind, text in
                .object([
                    "title": .string(title),
                    "sourceKind": .string(kind.rawValue),
                    "sourceText": .string(text)
                ])
            })
        ])
    }

    func toolCall(
        callID: String,
        tasks: [(String, TaskSourceKind, String)]
    ) -> CodexDynamicToolCall {
        CodexDynamicToolCall(
            threadID: "live-thread",
            turnID: "turn-1",
            callID: callID,
            namespace: nil,
            tool: LiveTaskDraftDecoder.toolName,
            arguments: toolArguments(tasks: tasks)
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: workspace)
    }
}

private final class FakeCredentialStore: LiveRealtimeCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: String?
    private var saves: [String] = []

    init(storedValue: String?) {
        self.storedValue = storedValue
    }

    var savedValues: [String] { lock.withLock { saves } }

    func load() throws -> String? { lock.withLock { storedValue } }

    func save(_ apiKey: String) throws {
        lock.withLock {
            storedValue = apiKey
            saves.append(apiKey)
        }
    }

    func delete() throws {
        lock.withLock { storedValue = nil }
    }
}

@MainActor
private final class ClientFactoryRecorder {
    private let client: MockRealtimeClient
    private(set) var apiKeys: [String] = []

    init(client: MockRealtimeClient) {
        self.client = client
    }

    func make(apiKey: String) -> any CodexRealtimeClient {
        apiKeys.append(apiKey)
        return client
    }
}

@MainActor
private final class MockRealtimeClient: CodexRealtimeClient {
    struct Registration {
        let threadID: String
        let tool: String
        let handler: CodexDynamicToolHandler
    }

    var connectionState: CodexConnectionState = .disconnected
    let realtimeEvents: AsyncStream<CodexRealtimeEvent>
    private let continuation: AsyncStream<CodexRealtimeEvent>.Continuation
    private let audioAppendGate: AsyncGate?
    private var registrations: [UUID: Registration] = [:]

    private(set) var liveThreadCWD: String?
    private(set) var liveTools: [CodexDynamicToolSpec] = []
    private(set) var realtimeThreadID: String?
    private(set) var realtimeOptions: CodexRealtimeStartOptions?
    private(set) var appendedAudio: [CodexRealtimeAudioChunk] = []
    private(set) var appendedTexts: [String] = []
    private(set) var didStopRealtime = false
    private(set) var didDisconnect = false
    private(set) var audioAppendStarted = 0
    private(set) var maximumConcurrentAudioAppends = 0
    private var activeAudioAppends = 0

    init(audioAppendGate: AsyncGate?) {
        self.audioAppendGate = audioAppendGate
        var captured: AsyncStream<CodexRealtimeEvent>.Continuation!
        realtimeEvents = AsyncStream { captured = $0 }
        continuation = captured
    }

    func send(_ event: CodexRealtimeEvent) {
        continuation.yield(event)
    }

    func connect() async throws {
        connectionState = .connected
    }

    func disconnect() {
        didDisconnect = true
        connectionState = .disconnected
    }

    func startLiveThread(
        cwd: String,
        model: String?,
        tools: [CodexDynamicToolSpec]
    ) async throws -> CodexStartedThread {
        liveThreadCWD = cwd
        liveTools = tools
        return CodexStartedThread(
            threadID: "live-thread",
            sessionID: "session-1",
            model: model ?? "codex-test",
            cwd: cwd
        )
    }

    func listRealtimeVoices() async throws -> CodexRealtimeVoiceCatalog {
        CodexRealtimeVoiceCatalog(v1: ["alloy"], v2: ["marin"], defaultV1: "alloy", defaultV2: "marin")
    }

    func startRealtime(threadID: String, options: CodexRealtimeStartOptions) async throws {
        realtimeThreadID = threadID
        realtimeOptions = options
    }

    func appendRealtimeAudio(threadID: String, chunk: CodexRealtimeAudioChunk) async throws {
        audioAppendStarted += 1
        activeAudioAppends += 1
        maximumConcurrentAudioAppends = max(maximumConcurrentAudioAppends, activeAudioAppends)
        if audioAppendStarted == 1, let audioAppendGate {
            await audioAppendGate.wait()
        }
        appendedAudio.append(chunk)
        activeAudioAppends -= 1
    }

    func appendRealtimeText(
        threadID: String,
        text: String,
        role: CodexRealtimeTextRole
    ) async throws {
        appendedTexts.append(text)
    }

    func appendRealtimeSpeech(threadID: String, text: String) async throws {}

    func stopRealtime(threadID: String) async throws {
        didStopRealtime = true
    }

    @discardableResult
    func registerDynamicToolHandler(
        threadID: String,
        tool: String,
        handler: @escaping CodexDynamicToolHandler
    ) -> UUID {
        let id = UUID()
        registrations[id] = Registration(threadID: threadID, tool: tool, handler: handler)
        return id
    }

    func unregisterDynamicToolHandler(_ registrationID: UUID) {
        registrations.removeValue(forKey: registrationID)
    }

    func invokeRegisteredTool(_ call: CodexDynamicToolCall) async -> CodexDynamicToolResult {
        guard let registration = registrations.values.first(where: {
            $0.threadID == call.threadID && $0.tool == call.tool
        }) else {
            return CodexDynamicToolResult(success: false, contentItems: [.text("not registered")])
        }
        return await registration.handler(call)
    }
}

private actor FakeLiveAudioService: LiveRealtimeAudioServicing {
    private var captureHandler: (@Sendable (RealtimeAudioBuffer) -> Void)?
    private var played: [RealtimeAudioBuffer] = []

    func permissionStatus() async -> RealtimeAudioPermission { .authorized }
    func requestPermission() async -> RealtimeAudioPermission { .authorized }

    func startCapture(
        onChunk: @escaping @Sendable (RealtimeAudioBuffer) -> Void
    ) async throws {
        captureHandler = onChunk
    }

    func stopCapture() async {
        captureHandler = nil
    }

    func play(_ chunk: RealtimeAudioBuffer) async throws {
        played.append(chunk)
    }

    func stopPlayback() async {}

    func stop() async {
        captureHandler = nil
    }

    func emit(_ buffer: RealtimeAudioBuffer) {
        captureHandler?(buffer)
    }

    func playedCount() -> Int { played.count }
}

@MainActor
private final class TaskCreationRecorder {
    struct Request: Equatable {
        let projectID: String
        let title: String
        let sourceKind: TaskSourceKind
        let sourceText: String
        let autoRun: Bool
    }

    private(set) var requests: [Request] = []

    func create(
        projectID: String,
        title: String,
        sourceKind: TaskSourceKind,
        sourceText: String,
        autoRun: Bool
    ) -> UUID? {
        requests.append(Request(
            projectID: projectID,
            title: title,
            sourceKind: sourceKind,
            sourceText: sourceText,
            autoRun: autoRun
        ))
        return UUID()
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
