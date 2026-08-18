import Darwin
import Foundation

enum BoardPersistenceError: LocalizedError, Sendable {
    case invalidDataPath(value: String)
    case createDirectoryFailed(path: String, reason: String)
    case readFailed(path: String, reason: String)
    case corruptFile(path: String, reason: String)
    case encodeFailed(reason: String)
    case writeFailed(path: String, reason: String)
    case permissionsFailed(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case let .invalidDataPath(value):
            "CODEXBOARD_DATA_PATH 必须是安全的绝对文件路径，当前值为：\(value)"
        case let .createDirectoryFailed(path, reason):
            "无法创建看板数据目录 \(path)：\(reason)"
        case let .readFailed(path, reason):
            "无法读取看板数据文件 \(path)：\(reason)"
        case let .corruptFile(path, reason):
            "看板数据文件已损坏，未覆盖原文件 \(path)：\(reason)"
        case let .encodeFailed(reason):
            "无法编码看板数据：\(reason)"
        case let .writeFailed(path, reason):
            "无法原子保存看板数据文件 \(path)：\(reason)"
        case let .permissionsFailed(path, reason):
            "无法保护看板数据权限 \(path)：\(reason)"
        }
    }
}

actor BoardPersistence {
    static let dataPathEnvironmentKey = "CODEXBOARD_DATA_PATH"

    private let fileURL: URL
    private let fileManager: FileManager
    private let configurationError: BoardPersistenceError?

    init(
        fileURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let fileManager = FileManager.default
        self.fileManager = fileManager

        if let fileURL {
            self.fileURL = fileURL.standardizedFileURL
            configurationError = nil
        } else if let configuredPath = environment[Self.dataPathEnvironmentKey] {
            let path = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedURL = URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
            if !path.isEmpty,
               (path as NSString).isAbsolutePath,
               resolvedURL.path != "/",
               !resolvedURL.lastPathComponent.isEmpty {
                self.fileURL = resolvedURL
                configurationError = nil
            } else {
                self.fileURL = fileManager.temporaryDirectory
                    .appendingPathComponent("CodexBoard-invalid-data-path", isDirectory: true)
                    .appendingPathComponent("board.json", isDirectory: false)
                configurationError = .invalidDataPath(value: configuredPath)
            }
        } else {
            self.fileURL = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Application Support/CodexBoard",
                    isDirectory: true
                )
                .appendingPathComponent("board.json", isDirectory: false)
                .standardizedFileURL
            configurationError = nil
        }
    }

    func load() throws -> BoardSnapshot {
        try validateConfiguration()
        guard let data = try existingData() else {
            return .empty
        }

        let snapshot = try decode(data)
        try secureExistingItemPermissions()
        return snapshot
    }

    func save(_ snapshot: BoardSnapshot) throws {
        try validateConfiguration()
        try prepareDirectory()

        // Refuse to replace an unreadable or malformed file. This preserves the
        // only recovery copy instead of silently resetting a user's board.
        if let currentData = try existingData() {
            _ = try decode(currentData)
        }

        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(snapshot)
        } catch {
            throw BoardPersistenceError.encodeFailed(reason: error.localizedDescription)
        }

        try atomicWrite(data)
    }

    private var directoryURL: URL {
        fileURL.deletingLastPathComponent()
    }

    private func validateConfiguration() throws {
        if let configurationError {
            throw configurationError
        }
    }

    private func existingData() throws -> Data? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            return nil
        }
        guard !isDirectory.boolValue else {
            throw BoardPersistenceError.readFailed(
                path: fileURL.path,
                reason: "目标路径是目录而不是文件"
            )
        }

        do {
            return try Data(contentsOf: fileURL, options: .mappedIfSafe)
        } catch {
            throw BoardPersistenceError.readFailed(
                path: fileURL.path,
                reason: error.localizedDescription
            )
        }
    }

    private func decode(_ data: Data) throws -> BoardSnapshot {
        do {
            return try JSONDecoder().decode(BoardSnapshot.self, from: data)
        } catch {
            throw BoardPersistenceError.corruptFile(
                path: fileURL.path,
                reason: error.localizedDescription
            )
        }
    }

    private func prepareDirectory() throws {
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        } catch {
            throw BoardPersistenceError.createDirectoryFailed(
                path: directoryURL.path,
                reason: error.localizedDescription
            )
        }

        try setPermissions(0o700, at: directoryURL)
    }

    private func secureExistingItemPermissions() throws {
        try setPermissions(0o700, at: directoryURL)
        try setPermissions(0o600, at: fileURL)
    }

    private func setPermissions(_ permissions: Int, at url: URL) throws {
        do {
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: permissions)],
                ofItemAtPath: url.path
            )
        } catch {
            throw BoardPersistenceError.permissionsFailed(
                path: url.path,
                reason: error.localizedDescription
            )
        }
    }

    private func atomicWrite(_ data: Data) throws {
        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )

        var descriptor: Int32 = -1
        var temporaryFileExists = false
        defer {
            if descriptor >= 0 {
                _ = Darwin.close(descriptor)
            }
            if temporaryFileExists {
                temporaryURL.path.withCString { path in
                    _ = Darwin.unlink(path)
                }
            }
        }

        descriptor = temporaryURL.path.withCString { path in
            Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw writeError(for: temporaryURL, code: errno)
        }
        temporaryFileExists = true

        do {
            try writeAll(data, to: descriptor, temporaryURL: temporaryURL)

            guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
                throw permissionsError(for: temporaryURL, code: errno)
            }
            guard Darwin.fsync(descriptor) == 0 else {
                throw writeError(for: temporaryURL, code: errno)
            }
            guard Darwin.close(descriptor) == 0 else {
                descriptor = -1
                throw writeError(for: temporaryURL, code: errno)
            }
            descriptor = -1

            let renameResult = temporaryURL.path.withCString { sourcePath in
                fileURL.path.withCString { destinationPath in
                    Darwin.rename(sourcePath, destinationPath)
                }
            }
            guard renameResult == 0 else {
                throw writeError(for: fileURL, code: errno)
            }
            temporaryFileExists = false
        } catch let error as BoardPersistenceError {
            throw error
        } catch {
            throw BoardPersistenceError.writeFailed(
                path: fileURL.path,
                reason: error.localizedDescription
            )
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32, temporaryURL: URL) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard let baseAddress = bytes.baseAddress else { return }
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw writeError(for: temporaryURL, code: errno)
                }
                guard result > 0 else {
                    throw BoardPersistenceError.writeFailed(
                        path: temporaryURL.path,
                        reason: "写入操作未取得进展"
                    )
                }
                offset += result
            }
        }
    }

    private func writeError(for url: URL, code: Int32) -> BoardPersistenceError {
        .writeFailed(path: url.path, reason: posixDescription(code))
    }

    private func permissionsError(for url: URL, code: Int32) -> BoardPersistenceError {
        .permissionsFailed(path: url.path, reason: posixDescription(code))
    }

    private func posixDescription(_ code: Int32) -> String {
        guard let message = Darwin.strerror(code) else {
            return "POSIX 错误 \(code)"
        }
        return String(cString: message)
    }
}
