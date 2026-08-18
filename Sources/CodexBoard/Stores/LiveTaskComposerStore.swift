import Combine
import Foundation

protocol LiveRealtimeCredentialStoring: Sendable {
    func load() throws -> String?
    func save(_ apiKey: String) throws
    func delete() throws
}

extension OpenAIRealtimeCredentialStore: LiveRealtimeCredentialStoring {}

protocol LiveRealtimeAudioServicing: Sendable {
    func permissionStatus() async -> RealtimeAudioPermission
    func requestPermission() async -> RealtimeAudioPermission
    func startCapture(
        onChunk: @escaping @Sendable (RealtimeAudioBuffer) -> Void
    ) async throws
    func stopCapture() async
    func play(_ chunk: RealtimeAudioBuffer) async throws
    func stopPlayback() async
    func stop() async
}

extension RealtimeAudioService: LiveRealtimeAudioServicing {}

typealias LiveRealtimeClientFactory = @MainActor @Sendable (String) -> any CodexRealtimeClient
typealias LiveWorkspaceProvider = @Sendable () throws -> URL
typealias LiveBoardTaskCreator = @MainActor @Sendable (
    _ projectID: String,
    _ title: String,
    _ sourceKind: TaskSourceKind,
    _ sourceText: String,
    _ autoRun: Bool
) -> UUID?

enum LiveTaskComposerState: Equatable, Sendable {
    case idle
    case connecting
    case startingThread
    case startingRealtime
    case live
    case requestingDrafts
    case reviewing
    case stopping
    case closed(reason: String?)
    case failed(message: String)

    var displayTitle: String {
        switch self {
        case .idle: "尚未开始"
        case .connecting: "正在连接"
        case .startingThread: "正在准备安全会话"
        case .startingRealtime: "正在启动 Live"
        case .live: "Live 已连接"
        case .requestingDrafts: "正在生成草稿"
        case .reviewing: "请预览任务草稿"
        case .stopping: "正在结束 Live"
        case let .closed(reason): reason?.isEmpty == false ? "Live 已结束：\(reason!)" : "Live 已结束"
        case .failed: "Live 连接失败"
        }
    }

    var isBusy: Bool {
        switch self {
        case .connecting, .startingThread, .startingRealtime, .requestingDrafts, .stopping:
            true
        default:
            false
        }
    }
}

enum LiveTaskComposerError: LocalizedError, Equatable, Sendable {
    case missingAPIKey
    case sessionNotReady
    case invalidDraft
    case taskCreationRejected
    case unsafeWorkspace(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "请输入 OpenAI API key。"
        case .sessionNotReady:
            "Live 会话尚未连接。"
        case .invalidDraft:
            "任务草稿不完整，请检查标题和任务内容。"
        case .taskCreationRejected:
            "看板拒绝创建任务；请确认项目仍然可用。"
        case let .unsafeWorkspace(path):
            "无法创建安全的 Live 工作区：\(path)"
        }
    }
}

enum LiveTaskWorkspace {
    static func makeSessionDirectory() throws -> URL {
        let fileManager = FileManager.default
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let boardDirectory = applicationSupport
            .appendingPathComponent("CodexBoard", isDirectory: true)
        let liveDirectory = boardDirectory
            .appendingPathComponent("LiveWorkspace", isDirectory: true)
        let sessionDirectory = liveDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        for directory in [boardDirectory, liveDirectory, sessionDirectory] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: directory.path
            )
            let values = try directory.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey
            ])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw LiveTaskComposerError.unsafeWorkspace(directory.path)
            }
        }

        let resolvedLive = liveDirectory.resolvingSymlinksInPath().standardizedFileURL
        let resolvedSession = sessionDirectory.resolvingSymlinksInPath().standardizedFileURL
        let requiredPrefix = resolvedLive.path.hasSuffix("/")
            ? resolvedLive.path
            : resolvedLive.path + "/"
        guard resolvedSession.path.hasPrefix(requiredPrefix),
              resolvedSession.path != "/"
        else {
            throw LiveTaskComposerError.unsafeWorkspace(resolvedSession.path)
        }
        return resolvedSession
    }
}

@MainActor
final class LiveTaskComposerStore: ObservableObject {
    let projectID: String
    let projectName: String
    let projectReference: String

    @Published var apiKey = ""
    @Published var rememberAPIKey = true
    @Published var voice = "marin"
    @Published var textInput = ""

    @Published private(set) var state: LiveTaskComposerState = .idle
    @Published private(set) var transcript: [LiveTranscriptEntry] = []
    @Published private(set) var liveTranscript = ""
    @Published private(set) var drafts: [LiveTaskDraft] = []
    @Published private(set) var isMicrophoneEnabled = false
    @Published private(set) var lastError: String?
    @Published private(set) var createdTaskIDs: [UUID] = []
    @Published private(set) var droppedAudioChunkCount = 0
    @Published private(set) var hasStoredAPIKey = false

    var isLive: Bool {
        switch state {
        case .live, .requestingDrafts, .reviewing:
            true
        default:
            false
        }
    }

    private let credentialStore: any LiveRealtimeCredentialStoring
    private let clientFactory: LiveRealtimeClientFactory
    private let audioService: any LiveRealtimeAudioServicing
    private let workspaceProvider: LiveWorkspaceProvider
    private let maxPendingAudioChunks: Int
    private let realtimeStartTimeout: TimeInterval
    private let draftRequestTimeout: TimeInterval
    private let createTask: LiveBoardTaskCreator

    private var client: (any CodexRealtimeClient)?
    private var threadID: String?
    private var sessionWorkspaceURL: URL?
    private var toolRegistrationID: UUID?
    private var eventTask: Task<Void, Never>?
    private var realtimeStartTimeoutTask: Task<Void, Never>?
    private var draftRequestTimeoutTask: Task<Void, Never>?
    private var audioUploadTask: Task<Void, Never>?
    private var pendingAudioBuffers: [RealtimeAudioBuffer] = []
    private var partialTranscriptRole: String?
    private var sessionAPIKey: String?
    private var sessionGeneration: UInt64 = 0
    private var captureGeneration: UInt64 = 0
    private var activeCaptureGeneration: UInt64?
    private var didReceiveRealtimeStarted = false
    private var didAttemptCredentialSave = false
    private var draftResultsByCallID: [String: CodexDynamicToolResult] = [:]
    private var confirmedTaskIDsByDraftID: [UUID: UUID] = [:]

    init(
        projectID: String,
        projectName: String,
        credentialStore: any LiveRealtimeCredentialStoring = OpenAIRealtimeCredentialStore(),
        clientFactory: @escaping LiveRealtimeClientFactory = { apiKey in
            CodexAppServerClient(launchMode: .realtimeLocal(apiKey: apiKey))
        },
        audioService: any LiveRealtimeAudioServicing = RealtimeAudioService(),
        workspaceProvider: @escaping LiveWorkspaceProvider = LiveTaskWorkspace.makeSessionDirectory,
        maxPendingAudioChunks: Int = 8,
        realtimeStartTimeout: TimeInterval = 15,
        draftRequestTimeout: TimeInterval = 20,
        createTask: @escaping LiveBoardTaskCreator
    ) {
        self.projectID = projectID
        self.projectName = projectName
        projectReference = "project-\(UUID().uuidString.lowercased())"
        self.credentialStore = credentialStore
        self.clientFactory = clientFactory
        self.audioService = audioService
        self.workspaceProvider = workspaceProvider
        self.maxPendingAudioChunks = max(1, maxPendingAudioChunks)
        self.realtimeStartTimeout = max(1, realtimeStartTimeout)
        self.draftRequestTimeout = max(0, draftRequestTimeout)
        self.createTask = createTask

        do {
            if let storedKey = try credentialStore.load() {
                apiKey = storedKey
                hasStoredAPIKey = true
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    deinit {
        eventTask?.cancel()
        realtimeStartTimeoutTask?.cancel()
        draftRequestTimeoutTask?.cancel()
        audioUploadTask?.cancel()
    }

    func start() async {
        switch state {
        case .idle, .closed, .failed:
            break
        default:
            return
        }

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            record(error: LiveTaskComposerError.missingAPIKey)
            return
        }

        sessionGeneration &+= 1
        let generation = sessionGeneration
        resetPresentationForNewSession()
        state = .connecting
        sessionAPIKey = trimmedKey

        let liveClient = clientFactory(trimmedKey)
        client = liveClient
        let events = liveClient.realtimeEvents
        eventTask = Task { @MainActor [weak self] in
            for await event in events {
                guard !Task.isCancelled else { break }
                await self?.handle(event, generation: generation)
            }
        }

        do {
            let workspace = try workspaceProvider()
            sessionWorkspaceURL = workspace
            try await liveClient.connect()
            guard generation == sessionGeneration else {
                liveClient.disconnect()
                return
            }

            state = .startingThread
            let startedThread = try await liveClient.startLiveThread(
                cwd: workspace.path,
                model: nil,
                tools: [LiveTaskDraftDecoder.toolSpec(projectReference: projectReference)]
            )
            guard generation == sessionGeneration else {
                liveClient.disconnect()
                return
            }
            threadID = startedThread.threadID
            toolRegistrationID = liveClient.registerDynamicToolHandler(
                threadID: startedThread.threadID,
                tool: LiveTaskDraftDecoder.toolName
            ) { [weak self] call in
                guard let self else {
                    return CodexDynamicToolResult(
                        success: false,
                        contentItems: [.text("Live 草稿会话已结束。")]
                    )
                }
                return await self.handleDraftToolCall(call, generation: generation)
            }

            state = .startingRealtime
            var options = CodexRealtimeStartOptions()
            options.voice = voice.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            options.includeStartupContext = false
            options.prompt = [
                Self.livePrompt(
                    projectName: projectName,
                    projectReference: projectReference
                ),
                Self.liveInstructions(
                    projectName: projectName,
                    projectReference: projectReference
                )
            ].joined(separator: "\n\n")
            try await liveClient.startRealtime(threadID: startedThread.threadID, options: options)
            guard generation == sessionGeneration else { return }
            scheduleRealtimeStartTimeout(generation: generation)
        } catch {
            guard generation == sessionGeneration else { return }
            await failSession(error.localizedDescription)
        }
    }

    func stop() async {
        guard client != nil || isLive || state.isBusy else {
            state = .closed(reason: nil)
            return
        }
        state = .stopping
        sessionGeneration &+= 1
        await tearDown(sendRealtimeStop: true, appendTrailingSilence: true)
        state = .closed(reason: nil)
    }

    func cancel() async {
        drafts.removeAll()
        confirmedTaskIDsByDraftID.removeAll()
        await stop()
    }

    func toggleMicrophone() async {
        await setMicrophoneEnabled(!isMicrophoneEnabled)
    }

    func setMicrophoneEnabled(_ enabled: Bool) async {
        if enabled {
            await enableMicrophone()
        } else {
            await disableMicrophone(appendTrailingSilence: true)
        }
    }

    func sendText() async {
        let text = textInput
        await sendText(text)
        if lastError == nil {
            textInput = ""
        }
    }

    func sendText(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard isLive, let client, let threadID else {
            record(error: LiveTaskComposerError.sessionNotReady)
            return
        }
        if activeCaptureGeneration != nil {
            await disableMicrophone(appendTrailingSilence: true)
        }
        do {
            try await client.appendRealtimeText(threadID: threadID, text: trimmed, role: .user)
            lastError = nil
            if case .reviewing = state { state = .live }
        } catch {
            record(error: error)
        }
    }

    func requestDrafts() async {
        guard isLive, let client, let threadID else {
            record(error: LiveTaskComposerError.sessionNotReady)
            return
        }
        if activeCaptureGeneration != nil {
            await disableMicrophone(appendTrailingSilence: true)
        }
        state = .requestingDrafts
        do {
            try await client.appendRealtimeText(
                threadID: threadID,
                text: "请把已经确认的需求整理成 1 到 5 个任务，并立即调用 \(LiveTaskDraftDecoder.toolName) 提交草稿。不要创建或执行任务。",
                role: .user
            )
            lastError = nil
            scheduleDraftRequestTimeout(generation: sessionGeneration)
        } catch {
            state = .live
            record(error: error)
        }
    }

    func updateDraft(_ draft: LiveTaskDraft) {
        guard draft.projectID == projectID,
              confirmedTaskIDsByDraftID[draft.id] == nil,
              let index = drafts.firstIndex(where: { $0.id == draft.id })
        else { return }
        drafts[index] = draft
    }

    func removeDraft(id: UUID) {
        guard confirmedTaskIDsByDraftID[id] == nil else { return }
        drafts.removeAll { $0.id == id }
        if drafts.isEmpty, isLive {
            state = .live
        }
    }

    @discardableResult
    func confirmDraft(id: UUID) -> UUID? {
        if let existing = confirmedTaskIDsByDraftID[id] {
            return existing
        }
        guard let draft = drafts.first(where: { $0.id == id }),
              let normalized = Self.normalizedDraft(draft)
        else {
            record(error: LiveTaskComposerError.invalidDraft)
            return nil
        }
        guard let taskID = createTask(
            projectID,
            normalized.title,
            normalized.sourceKind,
            normalized.sourceText,
            false
        ) else {
            record(error: LiveTaskComposerError.taskCreationRejected)
            return nil
        }
        confirmedTaskIDsByDraftID[id] = taskID
        if !createdTaskIDs.contains(taskID) {
            createdTaskIDs.append(taskID)
        }
        lastError = nil
        updateCreatedStateIfComplete()
        return taskID
    }

    @discardableResult
    func confirmAllDrafts() -> [UUID] {
        let ids = drafts.map(\.id)
        return ids.compactMap(confirmDraft(id:))
    }

    func confirmedTaskID(for draftID: UUID) -> UUID? {
        confirmedTaskIDsByDraftID[draftID]
    }

    func discardDrafts() {
        drafts.removeAll()
        if isLive {
            state = .live
        }
    }

    func deleteSavedAPIKey() {
        do {
            try credentialStore.delete()
            hasStoredAPIKey = false
            apiKey = ""
            lastError = nil
        } catch {
            record(error: error)
        }
    }

    private func enableMicrophone() async {
        guard !isMicrophoneEnabled, activeCaptureGeneration == nil else { return }
        guard isLive, threadID != nil else {
            record(error: LiveTaskComposerError.sessionNotReady)
            return
        }

        var permission = await audioService.permissionStatus()
        if permission == .notDetermined {
            permission = await audioService.requestPermission()
        }
        guard permission == .authorized else {
            record(error: RealtimeAudioServiceError.microphonePermissionDenied)
            return
        }

        captureGeneration &+= 1
        let thisCapture = captureGeneration
        let thisSession = sessionGeneration
        activeCaptureGeneration = thisCapture
        do {
            try await audioService.startCapture { [weak self] buffer in
                Task { @MainActor [weak self] in
                    self?.enqueueCapturedAudio(
                        buffer,
                        captureGeneration: thisCapture,
                        sessionGeneration: thisSession
                    )
                }
            }
            guard thisSession == sessionGeneration,
                  activeCaptureGeneration == thisCapture
            else {
                await audioService.stopCapture()
                return
            }
            isMicrophoneEnabled = true
            lastError = nil
        } catch {
            if activeCaptureGeneration == thisCapture {
                activeCaptureGeneration = nil
            }
            isMicrophoneEnabled = false
            record(error: error)
        }
    }

    private func disableMicrophone(appendTrailingSilence: Bool) async {
        guard activeCaptureGeneration != nil || isMicrophoneEnabled else { return }
        captureGeneration &+= 1
        activeCaptureGeneration = nil
        isMicrophoneEnabled = false
        await audioService.stopCapture()
        await flushAudioUploads()

        guard appendTrailingSilence, isLive, let client, let threadID else { return }
        do {
            try await client.appendRealtimeAudio(
                threadID: threadID,
                chunk: RealtimeAudioWireCodec.silence(milliseconds: 400)
            )
        } catch {
            record(error: error)
        }
    }

    private func enqueueCapturedAudio(
        _ buffer: RealtimeAudioBuffer,
        captureGeneration: UInt64,
        sessionGeneration: UInt64
    ) {
        guard self.sessionGeneration == sessionGeneration,
              activeCaptureGeneration == captureGeneration,
              client != nil,
              threadID != nil
        else { return }

        if pendingAudioBuffers.count >= maxPendingAudioChunks {
            pendingAudioBuffers.removeFirst()
            droppedAudioChunkCount += 1
        }
        pendingAudioBuffers.append(buffer)
        startAudioUploadIfNeeded(sessionGeneration: sessionGeneration)
    }

    private func startAudioUploadIfNeeded(sessionGeneration: UInt64) {
        guard audioUploadTask == nil else { return }
        audioUploadTask = Task { @MainActor [weak self] in
            await self?.drainAudioUploads(sessionGeneration: sessionGeneration)
        }
    }

    private func drainAudioUploads(sessionGeneration: UInt64) async {
        defer { audioUploadTask = nil }
        while !Task.isCancelled,
              self.sessionGeneration == sessionGeneration,
              !pendingAudioBuffers.isEmpty {
            let buffer = pendingAudioBuffers.removeFirst()
            guard let client, let threadID else { break }
            do {
                let chunk = try RealtimeAudioWireCodec.encodeCapture(buffer)
                try await client.appendRealtimeAudio(threadID: threadID, chunk: chunk)
            } catch {
                pendingAudioBuffers.removeAll()
                captureGeneration &+= 1
                activeCaptureGeneration = nil
                isMicrophoneEnabled = false
                record(error: error)
                await audioService.stopCapture()
                break
            }
        }
    }

    private func flushAudioUploads() async {
        while let task = audioUploadTask {
            await task.value
        }
    }

    private func handle(_ event: CodexRealtimeEvent, generation: UInt64) async {
        guard generation == sessionGeneration else { return }
        switch event {
        case let .started(eventThreadID, _, _):
            guard eventThreadID == threadID else { return }
            realtimeStartTimeoutTask?.cancel()
            realtimeStartTimeoutTask = nil
            state = .live
            lastError = nil
            didReceiveRealtimeStarted = true

        case let .transcriptDelta(eventThreadID, role, delta):
            guard eventThreadID == threadID else { return }
            if partialTranscriptRole != role, !liveTranscript.isEmpty,
               let oldRole = partialTranscriptRole {
                appendTranscript(role: oldRole, text: liveTranscript)
                liveTranscript = ""
            }
            partialTranscriptRole = role
            liveTranscript += delta
            if !delta.isEmpty { persistCredentialAfterRealtimeEvidence(generation: generation) }

        case let .transcriptDone(eventThreadID, role, text):
            guard eventThreadID == threadID else { return }
            appendTranscript(role: role, text: text)
            if !text.isEmpty { persistCredentialAfterRealtimeEvidence(generation: generation) }
            if partialTranscriptRole == role {
                partialTranscriptRole = nil
                liveTranscript = ""
            }

        case let .outputAudioDelta(eventThreadID, chunk):
            guard eventThreadID == threadID else { return }
            do {
                try await audioService.play(RealtimeAudioWireCodec.decodePlayback(chunk))
                persistCredentialAfterRealtimeEvidence(generation: generation)
            } catch {
                record(error: error)
            }

        case let .error(eventThreadID, message):
            guard eventThreadID == threadID else { return }
            await failSession(message)

        case let .closed(eventThreadID, reason):
            guard eventThreadID == threadID else { return }
            state = .closed(reason: reason)
            sessionGeneration &+= 1
            await tearDown(sendRealtimeStop: false, appendTrailingSilence: false)

        case let .connectionLost(message):
            await failSession(message)

        case .itemAdded, .sdp:
            break
        }
    }

    private func handleDraftToolCall(
        _ call: CodexDynamicToolCall,
        generation: UInt64
    ) async -> CodexDynamicToolResult {
        guard generation == sessionGeneration,
              call.threadID == threadID,
              call.tool == LiveTaskDraftDecoder.toolName
        else {
            return Self.failedToolResult("Live 草稿会话已结束或工具不匹配。")
        }
        if let cached = draftResultsByCallID[call.callID] {
            return cached
        }
        guard let object = call.arguments.objectValue,
              Set(object.keys) == Set(["projectRef", "tasks"])
        else {
            let result = Self.failedToolResult("任务草稿参数包含未知或缺失字段。")
            draftResultsByCallID[call.callID] = result
            return result
        }

        do {
            let decoded = try LiveTaskDraftDecoder.decode(
                call: call,
                projectReference: projectReference,
                projectID: projectID
            )
            drafts = decoded
            draftRequestTimeoutTask?.cancel()
            draftRequestTimeoutTask = nil
            state = .reviewing
            lastError = nil
            persistCredentialAfterRealtimeEvidence(generation: generation)
            let result = Self.successfulToolResult(decoded)
            draftResultsByCallID[call.callID] = result
            if activeCaptureGeneration != nil {
                Task { @MainActor [weak self] in
                    await self?.disableMicrophone(appendTrailingSilence: true)
                }
            }
            return result
        } catch {
            record(error: error)
            let result = Self.failedToolResult(error.localizedDescription)
            draftResultsByCallID[call.callID] = result
            return result
        }
    }

    private func appendTranscript(role: String, text: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        if transcript.last?.role == role, transcript.last?.text == normalized {
            return
        }
        transcript.append(LiveTranscriptEntry(role: role, text: normalized))
    }

    private func scheduleRealtimeStartTimeout(generation: UInt64) {
        realtimeStartTimeoutTask?.cancel()
        realtimeStartTimeoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.realtimeStartTimeout))
            guard !Task.isCancelled,
                  generation == self.sessionGeneration,
                  case .startingRealtime = self.state
            else { return }
            await self.failSession("等待 Realtime started 事件超时。")
        }
    }

    private func persistCredentialAfterRealtimeEvidence(generation: UInt64) {
        guard generation == sessionGeneration,
              didReceiveRealtimeStarted,
              !didAttemptCredentialSave,
              isLive,
              lastError == nil,
              rememberAPIKey,
              let sessionAPIKey
        else { return }
        didAttemptCredentialSave = true
        do {
            try credentialStore.save(sessionAPIKey)
            hasStoredAPIKey = true
        } catch {
            // The realtime session is already usable. Keychain failure is
            // intentionally non-fatal and never rolls the session back.
            record(error: error)
        }
    }

    private func scheduleDraftRequestTimeout(generation: UInt64) {
        draftRequestTimeoutTask?.cancel()
        draftRequestTimeoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if self.draftRequestTimeout > 0 {
                try? await Task.sleep(for: .seconds(self.draftRequestTimeout))
            }
            guard !Task.isCancelled,
                  generation == self.sessionGeneration,
                  case .requestingDrafts = self.state
            else { return }
            self.state = .live
            self.lastError = "未收到草稿，可补充需求后重试"
        }
    }

    private func failSession(_ message: String) async {
        lastError = message
        state = .failed(message: message)
        sessionGeneration &+= 1
        await tearDown(sendRealtimeStop: false, appendTrailingSilence: false)
    }

    private func tearDown(
        sendRealtimeStop: Bool,
        appendTrailingSilence: Bool
    ) async {
        realtimeStartTimeoutTask?.cancel()
        realtimeStartTimeoutTask = nil
        draftRequestTimeoutTask?.cancel()
        draftRequestTimeoutTask = nil

        captureGeneration &+= 1
        let hadCapture = activeCaptureGeneration != nil || isMicrophoneEnabled
        activeCaptureGeneration = nil
        isMicrophoneEnabled = false
        if hadCapture {
            await audioService.stopCapture()
        }
        await flushAudioUploads()

        if appendTrailingSilence, hadCapture, let client, let threadID {
            try? await client.appendRealtimeAudio(
                threadID: threadID,
                chunk: RealtimeAudioWireCodec.silence(milliseconds: 400)
            )
        }
        if sendRealtimeStop, let client, let threadID {
            try? await client.stopRealtime(threadID: threadID)
        }

        pendingAudioBuffers.removeAll()
        audioUploadTask?.cancel()
        audioUploadTask = nil
        await audioService.stop()

        if let client, let toolRegistrationID {
            client.unregisterDynamicToolHandler(toolRegistrationID)
        }
        toolRegistrationID = nil
        eventTask?.cancel()
        eventTask = nil
        client?.disconnect()
        client = nil
        threadID = nil
        sessionAPIKey = nil
        removeOwnedEmptySessionWorkspaceIfNeeded()
    }

    private func resetPresentationForNewSession() {
        realtimeStartTimeoutTask?.cancel()
        draftRequestTimeoutTask?.cancel()
        audioUploadTask?.cancel()
        pendingAudioBuffers.removeAll()
        transcript.removeAll()
        liveTranscript = ""
        partialTranscriptRole = nil
        drafts.removeAll()
        createdTaskIDs.removeAll()
        confirmedTaskIDsByDraftID.removeAll()
        draftResultsByCallID.removeAll()
        didReceiveRealtimeStarted = false
        didAttemptCredentialSave = false
        droppedAudioChunkCount = 0
        lastError = nil
    }

    private func updateCreatedStateIfComplete() {
        guard !drafts.isEmpty,
              drafts.allSatisfy({ confirmedTaskIDsByDraftID[$0.id] != nil })
        else { return }
        state = .reviewing
    }

    private func record(error: Error) {
        lastError = error.localizedDescription
    }

    private func removeOwnedEmptySessionWorkspaceIfNeeded() {
        defer { sessionWorkspaceURL = nil }
        guard let sessionWorkspaceURL,
              UUID(uuidString: sessionWorkspaceURL.lastPathComponent) != nil,
              sessionWorkspaceURL.deletingLastPathComponent().lastPathComponent == "LiveWorkspace",
              sessionWorkspaceURL.deletingLastPathComponent()
                .deletingLastPathComponent().lastPathComponent == "CodexBoard"
        else { return }

        let fileManager = FileManager.default
        guard let applicationSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return }
        let expectedLiveDirectory = applicationSupport
            .appendingPathComponent("CodexBoard", isDirectory: true)
            .appendingPathComponent("LiveWorkspace", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let actualLiveDirectory = sessionWorkspaceURL
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard actualLiveDirectory == expectedLiveDirectory,
              let contents = try? fileManager.contentsOfDirectory(
                at: sessionWorkspaceURL,
                includingPropertiesForKeys: nil,
                options: []
              ),
              contents.isEmpty
        else { return }
        try? fileManager.removeItem(at: sessionWorkspaceURL)
    }

    private static func normalizedDraft(_ draft: LiveTaskDraft) -> LiveTaskDraft? {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceText = draft.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,
              title.count <= 80,
              !sourceText.isEmpty,
              sourceText.count <= 20_000
        else { return nil }
        var normalized = draft
        normalized.title = title
        normalized.sourceText = sourceText
        return normalized
    }

    private static func successfulToolResult(_ drafts: [LiveTaskDraft]) -> CodexDynamicToolResult {
        let payload: [String: Any] = [
            "state": "awaitingConfirmation",
            "draftIds": drafts.map { $0.id.uuidString }
        ]
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let text = data.flatMap { String(data: $0, encoding: .utf8) }
            ?? "{\"state\":\"awaitingConfirmation\"}"
        return CodexDynamicToolResult(success: true, contentItems: [.text(text)])
    }

    private static func failedToolResult(_ message: String) -> CodexDynamicToolResult {
        CodexDynamicToolResult(success: false, contentItems: [.text(message)])
    }

    private static func livePrompt(projectName: String, projectReference: String) -> String {
        """
        你正在帮助用户为 CodexBoard 项目“\(projectName)”采集任务需求。
        项目引用是 \(projectReference)。通过对话澄清范围；只有用户要求生成草稿或需求已经明确时，调用 \(LiveTaskDraftDecoder.toolName)。
        工具只生成待确认草稿，不创建、不执行、不读取项目文件。
        """
    }

    private static func liveInstructions(projectName: String, projectReference: String) -> String {
        """
        这是只读需求采集会话。目标项目显示名为“\(projectName)”，opaque projectRef 为 \(projectReference)。
        不运行命令、不读取文件、不请求额外权限，也不要声称已经创建任务。需要提交时，只调用 \(LiveTaskDraftDecoder.toolName)，随后说明草稿仍需用户在界面确认。
        """
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
