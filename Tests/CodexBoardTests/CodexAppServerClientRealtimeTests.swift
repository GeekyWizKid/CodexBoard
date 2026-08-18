import Foundation
import XCTest
@testable import CodexBoard

@MainActor
final class CodexAppServerClientRealtimeTests: XCTestCase {
    func testRealtimeRequestsUseExpectedWireContract() async throws {
        let server = try RealtimeProtocolTestServer(scenario: .wireCapture)
        defer { server.remove() }
        let client = makeClient(server: server)
        defer { client.disconnect() }

        let inputSchema: JSONValue = .object([
            "type": .string("object"),
            "required": .array([.string("title")])
        ])
        let tool = CodexDynamicToolSpec(
            name: "submit_task_drafts",
            description: "Submit task drafts",
            inputSchema: inputSchema,
            deferLoading: true
        )

        try await client.connect()
        let thread = try await client.startLiveThread(
            cwd: "/tmp/live project",
            model: "gpt-realtime-2.1",
            tools: [tool]
        )
        XCTAssertEqual(
            thread,
            CodexStartedThread(
                threadID: "live-thread",
                sessionID: "session-1",
                model: "gpt-realtime-2.1",
                cwd: "/tmp/live project"
            )
        )

        let voices = try await client.listRealtimeVoices()
        XCTAssertEqual(
            voices,
            CodexRealtimeVoiceCatalog(
                v1: ["alloy"],
                v2: ["marin", "cedar"],
                defaultV1: "alloy",
                defaultV2: "marin"
            )
        )

        var options = CodexRealtimeStartOptions()
        options.outputModality = .audio
        options.model = "gpt-realtime-2.1"
        options.voice = "cedar"
        options.version = .v2
        options.prompt = "Help create tasks"
        options.includeStartupContext = true
        try await client.startRealtime(threadID: "live-thread", options: options)
        try await client.appendRealtimeText(
            threadID: "live-thread",
            text: "Create a board task",
            role: .developer
        )
        let audioData = Data([0x01, 0x00, 0x02, 0x00])
        let audio = try CodexRealtimeAudioChunk(
            data: audioData,
            sampleRate: 24_000,
            channelCount: 1,
            samplesPerChannel: 2,
            itemID: "audio-item-1"
        )
        try await client.appendRealtimeAudio(threadID: "live-thread", chunk: audio)
        try await client.stopRealtime(threadID: "live-thread")

        let messages = try await server.waitForLoggedMessages(count: 8)

        let initialize = try request(named: "initialize", in: messages)
        XCTAssertEqual(initialize["params"]?["capabilities"]?["experimentalApi"], .bool(true))
        XCTAssertEqual(initialize["params"]?["clientInfo"]?["name"], .string("codex_board"))
        _ = try request(named: "initialized", in: messages)

        let startThread = try request(named: "thread/start", in: messages)
        let threadParams = try XCTUnwrap(startThread["params"])
        XCTAssertEqual(threadParams["cwd"], .string("/tmp/live project"))
        XCTAssertEqual(threadParams["approvalPolicy"], .string("never"))
        XCTAssertEqual(threadParams["sandbox"], .string("read-only"))
        XCTAssertEqual(threadParams["serviceName"], .string("codex_board_live"))
        XCTAssertEqual(threadParams["ephemeral"], .bool(true))
        XCTAssertEqual(threadParams["runtimeWorkspaceRoots"], .array([.string("/tmp/live project")]))
        XCTAssertEqual(threadParams["environments"], .array([]))
        XCTAssertEqual(threadParams["model"], .string("gpt-realtime-2.1"))
        XCTAssertEqual(threadParams["dynamicTools"], .array([
            .object([
                "type": .string("function"),
                "name": .string("submit_task_drafts"),
                "description": .string("Submit task drafts"),
                "inputSchema": inputSchema,
                "deferLoading": .bool(true)
            ])
        ]))

        let listVoices = try request(named: "thread/realtime/listVoices", in: messages)
        XCTAssertEqual(listVoices["params"], .object([:]))

        let startRealtime = try request(named: "thread/realtime/start", in: messages)
        let realtimeParams = try XCTUnwrap(startRealtime["params"])
        XCTAssertEqual(Set(try XCTUnwrap(realtimeParams.objectValue).keys), Set([
            "threadId",
            "outputModality",
            "model",
            "voice",
            "version",
            "prompt",
            "includeStartupContext",
            "clientManagedHandoffs",
            "codexResponsesAsItems",
            "transport"
        ]))
        XCTAssertEqual(realtimeParams["threadId"], .string("live-thread"))
        XCTAssertEqual(realtimeParams["outputModality"], .string("audio"))
        XCTAssertEqual(realtimeParams["model"], .string("gpt-realtime-2.1"))
        XCTAssertEqual(realtimeParams["voice"], .string("cedar"))
        XCTAssertEqual(realtimeParams["version"], .string("v2"))
        XCTAssertEqual(realtimeParams["prompt"], .string("Help create tasks"))
        XCTAssertEqual(realtimeParams["includeStartupContext"], .bool(true))
        XCTAssertEqual(realtimeParams["clientManagedHandoffs"], .bool(false))
        XCTAssertEqual(realtimeParams["codexResponsesAsItems"], .bool(false))
        XCTAssertEqual(realtimeParams["transport"], .object(["type": .string("websocket")]))
        XCTAssertNil(realtimeParams["realtimeStartInstructions"])
        XCTAssertNil(realtimeParams["realtimeEndInstructions"])

        let appendText = try request(named: "thread/realtime/appendText", in: messages)
        XCTAssertEqual(appendText["params"], .object([
            "threadId": .string("live-thread"),
            "text": .string("Create a board task"),
            "role": .string("developer")
        ]))

        let appendAudio = try request(named: "thread/realtime/appendAudio", in: messages)
        XCTAssertEqual(appendAudio["params"], .object([
            "threadId": .string("live-thread"),
            "audio": .object([
                "data": .string(audioData.base64EncodedString()),
                "numChannels": .integer(1),
                "sampleRate": .integer(24_000),
                "samplesPerChannel": .integer(2),
                "itemId": .string("audio-item-1")
            ])
        ]))

        let stop = try request(named: "thread/realtime/stop", in: messages)
        XCTAssertEqual(stop["params"], .object(["threadId": .string("live-thread")]))
    }

    func testRealtimeNotificationsMapAllSupportedEventKinds() async throws {
        let server = try RealtimeProtocolTestServer(scenario: .notifications)
        defer { server.remove() }
        let client = makeClient(server: server)
        defer { client.disconnect() }

        let stream = client.realtimeEvents
        let eventTask = Task.detached {
            try await collectRealtimeEvents(from: stream, count: 8, timeout: .seconds(3))
        }

        try await client.connect()
        _ = try await client.listRealtimeVoices()
        let events = try await eventTask.value

        let audioData = Data([0x01, 0x00, 0x02, 0x00])
        let audio = try CodexRealtimeAudioChunk(
            data: audioData,
            sampleRate: 24_000,
            channelCount: 1,
            samplesPerChannel: 2,
            itemID: "audio-item-1"
        )
        XCTAssertEqual(events, [
            .started(threadID: "live-thread", version: .v2, sessionID: "realtime-session-1"),
            .itemAdded(
                threadID: "live-thread",
                item: .object(["id": .string("item-1"), "type": .string("message")])
            ),
            .transcriptDelta(threadID: "live-thread", role: "assistant", delta: "你"),
            .transcriptDone(threadID: "live-thread", role: "assistant", text: "你好"),
            .outputAudioDelta(threadID: "live-thread", chunk: audio),
            .sdp(threadID: "live-thread", sdp: "v=0"),
            .error(threadID: "live-thread", message: "boom"),
            .closed(threadID: "live-thread", reason: "user")
        ])
    }

    func testDynamicToolDuplicateCallIDInvokesHandlerOnceAndReusesResult() async throws {
        let server = try RealtimeProtocolTestServer(scenario: .duplicateToolCall)
        defer { server.remove() }
        let client = makeClient(server: server)
        defer { client.disconnect() }
        let releaseGate = RealtimeToolReleaseGate()
        let handlerStarted = expectation(description: "dynamic tool handler started")
        var invocationCount = 0
        var receivedCall: CodexDynamicToolCall?

        let registration = client.registerDynamicToolHandler(
            threadID: "live-thread",
            tool: "submit_task_drafts"
        ) { call in
            invocationCount += 1
            receivedCall = call
            handlerStarted.fulfill()
            await releaseGate.wait()
            return CodexDynamicToolResult(success: true, contentItems: [.text("accepted")])
        }
        defer { client.unregisterDynamicToolHandler(registration) }

        try await client.connect()
        await fulfillment(of: [handlerStarted], timeout: 2)
        await releaseGate.release()

        let responses = try await server.waitForLoggedMessages(count: 3)
        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(
            receivedCall,
            CodexDynamicToolCall(
                threadID: "live-thread",
                turnID: "turn-1",
                callID: "call-1",
                namespace: "codex_board",
                tool: "submit_task_drafts",
                arguments: .object(["projectRef": .string("project-token")])
            )
        )
        XCTAssertEqual(Set(responses.compactMap { $0["id"]?.intValue }), Set([900, 901, 902]))
        for response in responses {
            XCTAssertEqual(response["result"], .object([
                "success": .bool(true),
                "contentItems": .array([
                    .object([
                        "type": .string("inputText"),
                        "text": .string("accepted")
                    ])
                ])
            ]))
        }
    }

    private func makeClient(server: RealtimeProtocolTestServer) -> CodexAppServerClient {
        let executableURL = server.executableURL
        return CodexAppServerClient(
            requestTimeout: 3,
            transportFactory: {
                AppServerTransport(executableURL: executableURL, arguments: [])
            }
        )
    }

    private func request(named method: String, in messages: [JSONValue]) throws -> JSONValue {
        try XCTUnwrap(messages.first(where: { $0["method"]?.stringValue == method }))
    }
}

private enum RealtimeProtocolTestError: Error {
    case timedOutWaitingForLog(Int)
    case timedOutWaitingForEvents(Int)
    case realtimeStreamEnded
}

private func collectRealtimeEvents(
    from stream: AsyncStream<CodexRealtimeEvent>,
    count: Int,
    timeout: Duration
) async throws -> [CodexRealtimeEvent] {
    try await withThrowingTaskGroup(of: [CodexRealtimeEvent].self) { group in
        group.addTask {
            var events: [CodexRealtimeEvent] = []
            for await event in stream {
                events.append(event)
                if events.count == count { return events }
            }
            throw RealtimeProtocolTestError.realtimeStreamEnded
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw RealtimeProtocolTestError.timedOutWaitingForEvents(count)
        }
        defer { group.cancelAll() }
        guard let events = try await group.next() else {
            throw RealtimeProtocolTestError.realtimeStreamEnded
        }
        return events
    }
}

private actor RealtimeToolReleaseGate {
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isReleased { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let currentWaiters = waiters
        waiters.removeAll()
        currentWaiters.forEach { $0.resume() }
    }
}

private struct RealtimeProtocolTestServer: Sendable {
    enum Scenario {
        case wireCapture
        case notifications
        case duplicateToolCall
    }

    let directory: URL
    let executableURL: URL
    let logURL: URL

    init(scenario: Scenario) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CodexAppServerClientRealtimeTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executableURL = directory.appendingPathComponent("codex")
        logURL = directory.appendingPathComponent("wire.jsonl")
        try Data().write(to: logURL)

        let body: String
        switch scenario {
        case .wireCapture:
            body = Self.wireCaptureScript(logURL: logURL)
        case .notifications:
            body = Self.notificationScript
        case .duplicateToolCall:
            body = Self.duplicateToolCallScript(logURL: logURL)
        }
        let script = """
        #!/bin/sh
        set -eu
        \(body)
        """
        try Data(script.utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executableURL.path
        )
    }

    func waitForLoggedMessages(count: Int) async throws -> [JSONValue] {
        for _ in 0..<300 {
            let data = try Data(contentsOf: logURL)
            let lines = String(decoding: data, as: UTF8.self)
                .split(separator: "\n")
                .map(String.init)
            if lines.count >= count {
                return try lines.prefix(count).map { line in
                    try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RealtimeProtocolTestError.timedOutWaitingForLog(count)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func wireCaptureScript(logURL: URL) -> String {
        """
        LOG='\(logURL.path)'
        IFS= read -r line
        printf '%s\\n' "$line" >> "$LOG"
        printf '{"id":1,"result":{}}\\n'
        IFS= read -r line
        printf '%s\\n' "$line" >> "$LOG"
        IFS= read -r line
        printf '%s\\n' "$line" >> "$LOG"
        printf '{"id":2,"result":{"thread":{"id":"live-thread","sessionId":"session-1"},"cwd":"/tmp/live project","model":"gpt-realtime-2.1"}}\\n'
        IFS= read -r line
        printf '%s\\n' "$line" >> "$LOG"
        printf '{"id":3,"result":{"voices":{"v1":["alloy"],"v2":["marin","cedar"],"defaultV1":"alloy","defaultV2":"marin"}}}\\n'
        IFS= read -r line
        printf '%s\\n' "$line" >> "$LOG"
        printf '{"id":4,"result":{}}\\n'
        IFS= read -r line
        printf '%s\\n' "$line" >> "$LOG"
        printf '{"id":5,"result":{}}\\n'
        IFS= read -r line
        printf '%s\\n' "$line" >> "$LOG"
        printf '{"id":6,"result":{}}\\n'
        IFS= read -r line
        printf '%s\\n' "$line" >> "$LOG"
        printf '{"id":7,"result":{}}\\n'
        while IFS= read -r line; do printf '%s\\n' "$line" >> "$LOG"; done
        """
    }

    private static let notificationScript = """
    IFS= read -r initialize
    printf '{"id":1,"result":{}}\\n'
    IFS= read -r initialized
    IFS= read -r voices
    printf '{"id":2,"result":{"voices":{"v1":["alloy"],"v2":["marin"],"defaultV1":"alloy","defaultV2":"marin"}}}\\n'
    printf '{"method":"thread/realtime/started","params":{"threadId":"live-thread","version":"v2","realtimeSessionId":"realtime-session-1"}}\\n'
    printf '{"method":"thread/realtime/itemAdded","params":{"threadId":"live-thread","item":{"id":"item-1","type":"message"}}}\\n'
    printf '{"method":"thread/realtime/transcript/delta","params":{"threadId":"live-thread","role":"assistant","delta":"你"}}\\n'
    printf '{"method":"thread/realtime/transcript/done","params":{"threadId":"live-thread","role":"assistant","text":"你好"}}\\n'
    printf '{"method":"thread/realtime/outputAudio/delta","params":{"threadId":"live-thread","audio":{"data":"AQACAA==","sampleRate":24000,"numChannels":1,"samplesPerChannel":2,"itemId":"audio-item-1"}}}\\n'
    printf '{"method":"thread/realtime/sdp","params":{"threadId":"live-thread","sdp":"v=0"}}\\n'
    printf '{"method":"thread/realtime/error","params":{"threadId":"live-thread","message":"boom"}}\\n'
    printf '{"method":"thread/realtime/closed","params":{"threadId":"live-thread","reason":"user"}}\\n'
    while IFS= read -r ignored; do :; done
    """

    private static func duplicateToolCallScript(logURL: URL) -> String {
        """
        LOG='\(logURL.path)'
        IFS= read -r initialize
        printf '{"id":1,"result":{}}\\n'
        IFS= read -r initialized
        printf '{"id":900,"method":"item/tool/call","params":{"threadId":"live-thread","turnId":"turn-1","callId":"call-1","namespace":"codex_board","tool":"submit_task_drafts","arguments":{"projectRef":"project-token"}}}\\n'
        printf '{"id":901,"method":"item/tool/call","params":{"threadId":"live-thread","turnId":"turn-1","callId":"call-1","namespace":"codex_board","tool":"submit_task_drafts","arguments":{"projectRef":"project-token"}}}\\n'
        IFS= read -r line
        printf '%s\\n' "$line" >> "$LOG"
        IFS= read -r line
        printf '%s\\n' "$line" >> "$LOG"
        printf '{"id":902,"method":"item/tool/call","params":{"threadId":"live-thread","turnId":"turn-1","callId":"call-1","namespace":"codex_board","tool":"submit_task_drafts","arguments":{"projectRef":"project-token"}}}\\n'
        IFS= read -r line
        printf '%s\\n' "$line" >> "$LOG"
        while IFS= read -r ignored; do :; done
        """
    }
}
