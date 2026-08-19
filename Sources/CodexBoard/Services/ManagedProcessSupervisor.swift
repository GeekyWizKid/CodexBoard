import Darwin
import Foundation

/// Owns a single child process and its local process group.
///
/// `Foundation.Process` cannot safely be moved into a new process group after
/// `run()` returns: by then the child has already executed its image and
/// `setpgid` fails with `EACCES`. This supervisor uses `posix_spawn` with
/// `POSIX_SPAWN_SETPGROUP` so process-group ownership is established atomically
/// during launch.
final class ManagedProcessSupervisor: @unchecked Sendable {
    enum LaunchScope: Sendable, Equatable {
        /// The spawned process and its descendants are all expected to be local.
        case local
        /// The local process is an SSH client. Its remote descendants cannot be
        /// proven dead when the connection is interrupted or forcibly stopped.
        case ssh
    }

    enum ExitReason: Sendable, Equatable {
        case exited
        case uncaughtSignal
        case waitFailed(errno: Int32)
    }

    enum TerminationCertainty: Sendable, Equatable {
        /// The owned local process group no longer contains a process.
        case localProcessGroupDrained
        /// The local SSH process observed a successful remote-command exit.
        case remoteExitConfirmed
        /// The local SSH process ended, but the remote command's final state
        /// cannot be proven from this host.
        case remoteUnknown
        /// The process group still appeared to exist after the bounded KILL wait.
        case localProcessGroupUnknown
    }

    struct ExitEvent: Sendable, Equatable {
        let processIdentifier: pid_t
        /// Matches `Process.terminationStatus`: an exit code for `.exited`, or
        /// the terminating signal number for `.uncaughtSignal`.
        let status: Int32
        let reason: ExitReason
        let certainty: TerminationCertainty
        let stopWasRequested: Bool
        let escalatedToSIGKILL: Bool
    }

    enum StopResult: Sendable, Equatable {
        case notStarted
        case exited(ExitEvent)
        /// The bounded TERM/KILL sequence completed without reaping the leader.
        /// The single exit callback will still fire if the kernel later reaps it.
        case timedOut(TerminationCertainty)
    }

    struct StandardIO: @unchecked Sendable {
        let input: FileHandle
        let output: FileHandle
        let error: FileHandle
    }

    enum SupervisorError: Error, Sendable, Equatable {
        case alreadyStarted
        case pipeCreationFailed(errno: Int32)
        case spawnSetupFailed(operation: String, code: Int32)
        case launchFailed(code: Int32)
    }

    typealias ExitHandler = @Sendable (ExitEvent) -> Void

    private let scope: LaunchScope
    private let gracefulTerminationTimeout: TimeInterval
    private let forcedTerminationTimeout: TimeInterval
    private let pollInterval: TimeInterval
    private let exitHandler: ExitHandler
    private let condition = NSCondition()
    private let reaperQueue = DispatchQueue(
        label: "com.local.CodexBoard.managed-process.reaper",
        qos: .utility
    )

    private var didAttemptLaunch = false
    private var processID: pid_t?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var stopRequested = false
    private var shutdownCoordinatorActive = false
    private var didEscalateToSIGKILL = false
    private var exitEvent: ExitEvent?
    private var didDeliverExit = false

    init(
        scope: LaunchScope,
        gracefulTerminationTimeout: TimeInterval = 0.75,
        forcedTerminationTimeout: TimeInterval = 0.5,
        pollInterval: TimeInterval = 0.01,
        exitHandler: @escaping ExitHandler
    ) {
        self.scope = scope
        self.gracefulTerminationTimeout = max(0, gracefulTerminationTimeout)
        self.forcedTerminationTimeout = max(0, forcedTerminationTimeout)
        self.pollInterval = max(0.001, pollInterval)
        self.exitHandler = exitHandler
    }

    var processIdentifier: pid_t? {
        condition.lock()
        defer { condition.unlock() }
        return processID
    }

    var processGroupIdentifier: pid_t? {
        processIdentifier
    }

    var isRunning: Bool {
        condition.lock()
        defer { condition.unlock() }
        return processID != nil && exitEvent == nil
    }

    @discardableResult
    func launch(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) throws -> StandardIO {
        condition.lock()
        guard !didAttemptLaunch else {
            condition.unlock()
            throw SupervisorError.alreadyStarted
        }
        didAttemptLaunch = true
        condition.unlock()

        let stdinPipe = try Self.makePipe()
        var descriptorsToClose = [
            stdinPipe.read,
            stdinPipe.write
        ]

        let stdoutPipe: PipeDescriptors
        do {
            stdoutPipe = try Self.makePipe()
            descriptorsToClose.append(contentsOf: [stdoutPipe.read, stdoutPipe.write])
        } catch {
            Self.closeDescriptors(descriptorsToClose)
            throw error
        }

        let stderrPipe: PipeDescriptors
        do {
            stderrPipe = try Self.makePipe()
            descriptorsToClose.append(contentsOf: [stderrPipe.read, stderrPipe.write])
        } catch {
            Self.closeDescriptors(descriptorsToClose)
            throw error
        }

        do {
            try Self.setCloseOnExec(descriptorsToClose)
        } catch {
            Self.closeDescriptors(descriptorsToClose)
            throw error
        }

        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        do {
            try Self.checkSpawnSetup(
                posix_spawn_file_actions_init(&fileActions),
                operation: "posix_spawn_file_actions_init"
            )
            try Self.checkSpawnSetup(
                posix_spawnattr_init(&attributes),
                operation: "posix_spawnattr_init"
            )
            try Self.checkSpawnSetup(
                posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)),
                operation: "posix_spawnattr_setflags"
            )
            // A pgroup of zero asks the kernel to use the child's PID. This is
            // the race-free equivalent of `setpgid(child, child)`.
            try Self.checkSpawnSetup(
                posix_spawnattr_setpgroup(&attributes, 0),
                operation: "posix_spawnattr_setpgroup"
            )

            try Self.addDuplicate(
                from: stdinPipe.read,
                to: STDIN_FILENO,
                actions: &fileActions
            )
            try Self.addDuplicate(
                from: stdoutPipe.write,
                to: STDOUT_FILENO,
                actions: &fileActions
            )
            try Self.addDuplicate(
                from: stderrPipe.write,
                to: STDERR_FILENO,
                actions: &fileActions
            )
            for descriptor in descriptorsToClose {
                try Self.checkSpawnSetup(
                    posix_spawn_file_actions_addclose(&fileActions, descriptor),
                    operation: "posix_spawn_file_actions_addclose"
                )
            }
        } catch {
            if fileActions != nil { posix_spawn_file_actions_destroy(&fileActions) }
            if attributes != nil { posix_spawnattr_destroy(&attributes) }
            Self.closeDescriptors(descriptorsToClose)
            throw error
        }

        defer {
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attributes)
        }

        var spawnedPID: pid_t = 0
        let executablePath = executableURL.path
        let argv = [executablePath] + arguments
        let envp = environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        let launchCode = Self.withMutableCStringArray(argv) { argumentPointers in
            Self.withMutableCStringArray(envp) { environmentPointers in
                executablePath.withCString { executablePointer in
                    posix_spawn(
                        &spawnedPID,
                        executablePointer,
                        &fileActions,
                        &attributes,
                        argumentPointers,
                        environmentPointers
                    )
                }
            }
        }

        guard launchCode == 0 else {
            Self.closeDescriptors(descriptorsToClose)
            throw SupervisorError.launchFailed(code: launchCode)
        }

        // The child owns these ends after spawn. The parent must close them so
        // stdin EOF and stdout/stderr EOF remain observable.
        Self.closeDescriptors([stdinPipe.read, stdoutPipe.write, stderrPipe.write])
        descriptorsToClose.removeAll()

        let standardIO = StandardIO(
            input: FileHandle(fileDescriptor: stdinPipe.write, closeOnDealloc: true),
            output: FileHandle(fileDescriptor: stdoutPipe.read, closeOnDealloc: true),
            error: FileHandle(fileDescriptor: stderrPipe.read, closeOnDealloc: true)
        )

        condition.lock()
        processID = spawnedPID
        inputHandle = standardIO.input
        outputHandle = standardIO.output
        errorHandle = standardIO.error
        condition.broadcast()
        condition.unlock()

        let launchedPID = spawnedPID
        reaperQueue.async { [self, launchedPID] in
            reapLeader(processIdentifier: launchedPID)
        }
        return standardIO
    }

    /// Closes the child's stdin exactly once. This is always the first step of
    /// managed shutdown so a cooperative stdio server can observe EOF.
    func closeStandardInput() {
        let handle: FileHandle?
        condition.lock()
        handle = inputHandle
        inputHandle = nil
        condition.unlock()
        try? handle?.close()
    }

    /// Performs a bounded, idempotent close -> TERM -> wait -> KILL sequence.
    /// A single concurrent caller coordinates signals; all callers observe the
    /// same eventual `ExitEvent` or a bounded timeout.
    @discardableResult
    func stop() -> StopResult {
        let pid: pid_t
        var shouldCoordinate = false

        condition.lock()
        if let exitEvent {
            condition.unlock()
            return .exited(exitEvent)
        }
        guard let processID else {
            condition.unlock()
            return .notStarted
        }
        pid = processID
        stopRequested = true
        if !shutdownCoordinatorActive {
            shutdownCoordinatorActive = true
            shouldCoordinate = true
        }
        condition.unlock()

        closeStandardInput()

        var coordinatedEvent: ExitEvent?
        if shouldCoordinate {
            _ = Self.signalProcessGroup(pid, signal: SIGTERM)
            coordinatedEvent = waitForExit(timeout: gracefulTerminationTimeout)
            if coordinatedEvent == nil {
                condition.lock()
                didEscalateToSIGKILL = true
                condition.unlock()
                _ = Self.signalProcessGroup(pid, signal: SIGKILL)
                coordinatedEvent = waitForExit(
                    timeout: gracefulTerminationTimeout + forcedTerminationTimeout
                )
            }

            condition.lock()
            shutdownCoordinatorActive = false
            condition.broadcast()
            condition.unlock()

            if let coordinatedEvent { return .exited(coordinatedEvent) }
            return .timedOut(scope == .ssh ? .remoteUnknown : .localProcessGroupUnknown)
        }

        if let event = waitForExit(
            timeout: gracefulTerminationTimeout + forcedTerminationTimeout
        ) {
            return .exited(event)
        }
        return .timedOut(scope == .ssh ? .remoteUnknown : .localProcessGroupUnknown)
    }

    func waitForExit(timeout: TimeInterval) -> ExitEvent? {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        condition.lock()
        defer { condition.unlock() }
        while exitEvent == nil {
            guard condition.wait(until: deadline) else { break }
        }
        return exitEvent
    }

    private func reapLeader(processIdentifier: pid_t) {
        var rawStatus: Int32 = 0
        var waitError: Int32?
        while true {
            let result = waitpid(processIdentifier, &rawStatus, 0)
            if result == processIdentifier { break }
            if result == -1, errno == EINTR { continue }
            waitError = result == -1 ? errno : ECHILD
            break
        }

        closeStandardInput()
        let groupWasDrained = drainDescendants(ofProcessGroup: processIdentifier)

        condition.lock()
        let stopWasRequested = stopRequested
        let escalated = didEscalateToSIGKILL
        let event: ExitEvent
        if let waitError {
            event = ExitEvent(
                processIdentifier: processIdentifier,
                status: -1,
                reason: .waitFailed(errno: waitError),
                certainty: certainty(
                    rawStatus: nil,
                    groupWasDrained: groupWasDrained,
                    stopWasRequested: stopWasRequested
                ),
                stopWasRequested: stopWasRequested,
                escalatedToSIGKILL: escalated
            )
        } else {
            let decoded = Self.decodeWaitStatus(rawStatus)
            event = ExitEvent(
                processIdentifier: processIdentifier,
                status: decoded.status,
                reason: decoded.reason,
                certainty: certainty(
                    rawStatus: decoded,
                    groupWasDrained: groupWasDrained,
                    stopWasRequested: stopWasRequested
                ),
                stopWasRequested: stopWasRequested,
                escalatedToSIGKILL: escalated
            )
        }
        exitEvent = event
        condition.broadcast()
        let shouldDeliver = !didDeliverExit
        didDeliverExit = true
        condition.unlock()

        if shouldDeliver { exitHandler(event) }
    }

    private func drainDescendants(ofProcessGroup processGroup: pid_t) -> Bool {
        guard Self.processGroupExists(processGroup) else { return true }

        _ = Self.signalProcessGroup(processGroup, signal: SIGTERM)
        if waitForProcessGroupToDrain(
            processGroup,
            timeout: gracefulTerminationTimeout
        ) {
            return true
        }

        condition.lock()
        didEscalateToSIGKILL = true
        condition.unlock()
        _ = Self.signalProcessGroup(processGroup, signal: SIGKILL)
        return waitForProcessGroupToDrain(
            processGroup,
            timeout: forcedTerminationTimeout
        )
    }

    private func waitForProcessGroupToDrain(
        _ processGroup: pid_t,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        repeat {
            if !Self.processGroupExists(processGroup) { return true }
            Thread.sleep(forTimeInterval: pollInterval)
        } while Date() < deadline
        return !Self.processGroupExists(processGroup)
    }

    private func certainty(
        rawStatus: (status: Int32, reason: ExitReason)?,
        groupWasDrained: Bool,
        stopWasRequested: Bool
    ) -> TerminationCertainty {
        guard scope == .ssh else {
            return groupWasDrained ? .localProcessGroupDrained : .localProcessGroupUnknown
        }
        guard !stopWasRequested,
              groupWasDrained,
              rawStatus?.reason == .exited,
              rawStatus?.status == 0
        else {
            return .remoteUnknown
        }
        return .remoteExitConfirmed
    }

    private static func makePipe() throws -> PipeDescriptors {
        var descriptors = [Int32](repeating: -1, count: 2)
        let result = descriptors.withUnsafeMutableBufferPointer { buffer in
            Darwin.pipe(buffer.baseAddress!)
        }
        guard result == 0 else {
            throw SupervisorError.pipeCreationFailed(errno: errno)
        }
        return PipeDescriptors(read: descriptors[0], write: descriptors[1])
    }

    private static func setCloseOnExec(_ descriptors: [Int32]) throws {
        for descriptor in descriptors {
            guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) != -1 else {
                throw SupervisorError.spawnSetupFailed(
                    operation: "fcntl(FD_CLOEXEC)",
                    code: errno
                )
            }
        }
    }

    private static func addDuplicate(
        from source: Int32,
        to destination: Int32,
        actions: inout posix_spawn_file_actions_t?
    ) throws {
        try checkSpawnSetup(
            posix_spawn_file_actions_adddup2(&actions, source, destination),
            operation: "posix_spawn_file_actions_adddup2"
        )
    }

    private static func checkSpawnSetup(_ code: Int32, operation: String) throws {
        guard code == 0 else {
            throw SupervisorError.spawnSetupFailed(operation: operation, code: code)
        }
    }

    private static func withMutableCStringArray<Result>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        var pointers = strings.map { strdup($0) }
        pointers.append(nil)
        defer {
            for pointer in pointers where pointer != nil { free(pointer) }
        }
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }

    private static func closeDescriptors(_ descriptors: [Int32]) {
        for descriptor in descriptors where descriptor >= 0 {
            Darwin.close(descriptor)
        }
    }

    private static func signalProcessGroup(_ processGroup: pid_t, signal: Int32) -> Bool {
        guard processGroup > 1, processGroup != getpgrp() else { return false }
        if Darwin.kill(-processGroup, signal) == 0 { return true }
        return errno == ESRCH
    }

    private static func processGroupExists(_ processGroup: pid_t) -> Bool {
        guard processGroup > 1, processGroup != getpgrp() else { return false }
        if Darwin.kill(-processGroup, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func decodeWaitStatus(
        _ rawStatus: Int32
    ) -> (status: Int32, reason: ExitReason) {
        // Darwin's wait-status helpers are function-like C macros and are not
        // imported into Swift. `_WSTATUS` is the low seven bits.
        let signal = rawStatus & 0x7F
        if signal == 0 {
            return ((rawStatus >> 8) & 0xFF, .exited)
        }
        return (signal, .uncaughtSignal)
    }
}

private struct PipeDescriptors {
    let read: Int32
    let write: Int32
}
