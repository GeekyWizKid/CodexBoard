import Foundation
import XCTest
@testable import CodexBoard

@MainActor
final class CodexAppServerClientConnectionTests: XCTestCase {
    func testDisconnectDuringInitializeLeavesClientDisconnected() async throws {
        let server = try ConnectionTestServer(initializeDelaySeconds: 1)
        defer { server.remove() }
        let client = CodexAppServerClient(
            requestTimeout: 2,
            transportFactory: {
                AppServerTransport(executableURL: server.executableURL)
            }
        )
        defer { client.disconnect() }

        let connection = Task { @MainActor in
            await Self.connectError(from: client)
        }
        try await Self.waitUntilFileExists(server.initializeMarkerURL)

        client.disconnect()

        let connectionError = await connection.value
        XCTAssertEqual(connectionError, .disconnected)
        XCTAssertEqual(client.connectionState, .disconnected)
    }

    func testDisconnectInvalidatesSuspendedAttemptAndReleasesItsWaiters() async throws {
        let server = try ConnectionTestServer()
        defer { server.remove() }
        let factory = SequencedTransportFactory(
            first: AppServerTransport(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: []
            ),
            second: AppServerTransport(executableURL: server.executableURL)
        )
        let client = CodexAppServerClient(
            requestTimeout: 2,
            transportFactory: { await factory.makeTransport() }
        )
        defer { client.disconnect() }

        let firstConnection = Task { @MainActor in
            await Self.connectError(from: client)
        }
        await factory.waitUntilFirstInvocationIsSuspended()

        let waiterStarted = expectation(description: "second caller entered connect")
        let waiterFinished = expectation(description: "connect waiter released by disconnect")
        let waitingConnection = Task { @MainActor in
            waiterStarted.fulfill()
            let error = await Self.connectError(from: client)
            waiterFinished.fulfill()
            return error
        }
        await fulfillment(of: [waiterStarted], timeout: 1)
        await Task.yield()

        client.disconnect()

        await fulfillment(of: [waiterFinished], timeout: 1)
        let waitingConnectionError = await waitingConnection.value
        XCTAssertEqual(waitingConnectionError, .disconnected)
        XCTAssertEqual(client.connectionState, .disconnected)

        try await client.connect()
        XCTAssertEqual(client.connectionState, .connected)

        await factory.releaseFirstInvocation()
        let firstConnectionError = await firstConnection.value
        XCTAssertEqual(firstConnectionError, .disconnected)
        XCTAssertEqual(client.connectionState, .connected)
    }

    private static func connectError(from client: CodexAppServerClient) async -> CodexClientError? {
        do {
            try await client.connect()
            return nil
        } catch let error as CodexClientError {
            return error
        } catch {
            return .invalidResponse(error.localizedDescription)
        }
    }

    private static func waitUntilFileExists(_ url: URL) async throws {
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: url.path) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ConnectionTestError.timedOutWaitingForInitialize
    }
}

private enum ConnectionTestError: Error {
    case timedOutWaitingForInitialize
}

private actor SequencedTransportFactory {
    private let first: AppServerTransport
    private let second: AppServerTransport
    private var invocationCount = 0
    private var firstInvocationContinuation: CheckedContinuation<AppServerTransport, Never>?
    private var firstInvocationWaiters: [CheckedContinuation<Void, Never>] = []

    init(first: AppServerTransport, second: AppServerTransport) {
        self.first = first
        self.second = second
    }

    func makeTransport() async -> AppServerTransport {
        invocationCount += 1
        guard invocationCount == 1 else { return second }
        let waiters = firstInvocationWaiters
        firstInvocationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        return await withCheckedContinuation { continuation in
            firstInvocationContinuation = continuation
        }
    }

    func waitUntilFirstInvocationIsSuspended() async {
        if firstInvocationContinuation != nil { return }
        await withCheckedContinuation { continuation in
            firstInvocationWaiters.append(continuation)
        }
    }

    func releaseFirstInvocation() {
        let continuation = firstInvocationContinuation
        firstInvocationContinuation = nil
        continuation?.resume(returning: first)
    }
}

private struct ConnectionTestServer {
    let directory: URL
    let executableURL: URL
    let initializeMarkerURL: URL

    init(initializeDelaySeconds: Int = 0) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexAppServerClientConnectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executableURL = directory.appendingPathComponent("codex")
        initializeMarkerURL = directory.appendingPathComponent("initialize-received")
        let script = """
        #!/bin/sh
        IFS= read -r initialize
        : > '\(initializeMarkerURL.path)'
        /bin/sleep \(initializeDelaySeconds)
        printf '{"id":1,"result":{}}\\n'
        IFS= read -r initialized
        while IFS= read -r ignored; do :; done
        """
        try Data(script.utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executableURL.path
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
