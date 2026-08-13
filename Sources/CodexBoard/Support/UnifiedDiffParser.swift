import Foundation

struct UnifiedDiffDocument: Hashable, Sendable {
    let files: [UnifiedDiffFile]
    let additions: Int
    let deletions: Int

    var changedLineCount: Int { additions + deletions }
}

struct UnifiedDiffFile: Hashable, Identifiable, Sendable {
    let id: Int
    let path: String
    let oldPath: String?
    let newPath: String?
    let kind: UnifiedDiffFileKind
    let lines: [UnifiedDiffLine]
    let additions: Int
    let deletions: Int
    let rawPatch: String

    var filename: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    var parentPath: String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent == "." || parent == "/" ? "" : parent
    }
}

enum UnifiedDiffFileKind: String, Hashable, Sendable {
    case added
    case modified
    case deleted
    case renamed
    case binary

    var badge: String {
        switch self {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .renamed: "R"
        case .binary: "B"
        }
    }

    var title: String {
        switch self {
        case .added: "新增"
        case .modified: "修改"
        case .deleted: "删除"
        case .renamed: "重命名"
        case .binary: "二进制"
        }
    }
}

struct UnifiedDiffLine: Hashable, Sendable {
    let kind: UnifiedDiffLineKind
    let text: String
    let oldLineNumber: Int?
    let newLineNumber: Int?

    var marker: String {
        switch kind {
        case .addition: "+"
        case .deletion: "−"
        case .context: " "
        case .fileHeader, .hunk, .metadata: ""
        }
    }

    var content: String {
        switch kind {
        case .addition, .deletion, .context:
            return text.isEmpty ? "" : String(text.dropFirst())
        case .fileHeader, .hunk, .metadata:
            return text
        }
    }
}

enum UnifiedDiffLineKind: Hashable, Sendable {
    case fileHeader
    case hunk
    case addition
    case deletion
    case context
    case metadata
}

enum UnifiedDiffParser {
    static func parse(_ diff: String) -> UnifiedDiffDocument {
        var files: [UnifiedDiffFile] = []
        var builder: DiffFileBuilder?
        var oldLineNumber: Int?
        var newLineNumber: Int?

        func finishFile() {
            guard var current = builder else { return }
            current.resolveKindAndPath()
            files.append(current.makeFile(id: files.count))
            builder = nil
            oldLineNumber = nil
            newLineNumber = nil
        }

        for rawLine in diff.components(separatedBy: "\n") {
            if rawLine.hasPrefix("diff --git ") {
                finishFile()
                let paths = parseDiffHeader(rawLine)
                builder = DiffFileBuilder(oldPath: paths.old, newPath: paths.new)
                builder?.append(rawLine, kind: .fileHeader)
                continue
            }

            if builder == nil {
                guard rawLine.hasPrefix("--- ")
                        || rawLine.hasPrefix("+++ ")
                        || rawLine.hasPrefix("Binary files ")
                        || rawLine == "GIT binary patch"
                else { continue }
                builder = DiffFileBuilder(oldPath: nil, newPath: nil)
            }

            if rawLine.hasPrefix("--- "), oldLineNumber == nil, newLineNumber == nil {
                builder?.oldPath = parsePathHeader(rawLine, prefix: "--- ")
                builder?.append(rawLine, kind: .fileHeader)
            } else if rawLine.hasPrefix("+++ "), oldLineNumber == nil, newLineNumber == nil {
                builder?.newPath = parsePathHeader(rawLine, prefix: "+++ ")
                builder?.append(rawLine, kind: .fileHeader)
            } else if rawLine.hasPrefix("new file mode ") {
                builder?.kind = .added
                builder?.append(rawLine, kind: .metadata)
            } else if rawLine.hasPrefix("deleted file mode ") {
                builder?.kind = .deleted
                builder?.append(rawLine, kind: .metadata)
            } else if rawLine.hasPrefix("rename from ") {
                builder?.kind = .renamed
                builder?.oldPath = decodeGitPath(String(rawLine.dropFirst("rename from ".count)))
                builder?.append(rawLine, kind: .metadata)
            } else if rawLine.hasPrefix("rename to ") {
                builder?.kind = .renamed
                builder?.newPath = decodeGitPath(String(rawLine.dropFirst("rename to ".count)))
                builder?.append(rawLine, kind: .metadata)
            } else if rawLine.hasPrefix("Binary files ") || rawLine == "GIT binary patch" {
                builder?.kind = .binary
                builder?.append(rawLine, kind: .metadata)
            } else if rawLine.hasPrefix("@@") {
                let starts = parseHunkStarts(rawLine)
                oldLineNumber = starts.old
                newLineNumber = starts.new
                builder?.append(rawLine, kind: .hunk)
            } else if rawLine.hasPrefix("+"), newLineNumber != nil {
                builder?.append(
                    rawLine,
                    kind: .addition,
                    oldLineNumber: nil,
                    newLineNumber: newLineNumber
                )
                newLineNumber? += 1
                builder?.additions += 1
            } else if rawLine.hasPrefix("-"), oldLineNumber != nil {
                builder?.append(
                    rawLine,
                    kind: .deletion,
                    oldLineNumber: oldLineNumber,
                    newLineNumber: nil
                )
                oldLineNumber? += 1
                builder?.deletions += 1
            } else if rawLine.hasPrefix(" "), oldLineNumber != nil, newLineNumber != nil {
                builder?.append(
                    rawLine,
                    kind: .context,
                    oldLineNumber: oldLineNumber,
                    newLineNumber: newLineNumber
                )
                oldLineNumber? += 1
                newLineNumber? += 1
            } else {
                builder?.append(rawLine, kind: .metadata)
            }
        }
        finishFile()

        return UnifiedDiffDocument(
            files: files,
            additions: files.reduce(0) { $0 + $1.additions },
            deletions: files.reduce(0) { $0 + $1.deletions }
        )
    }

    private static func parseHunkStarts(_ line: String) -> (old: Int?, new: Int?) {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 3 else { return (nil, nil) }
        return (lineNumber(in: parts[1], prefix: "-"), lineNumber(in: parts[2], prefix: "+"))
    }

    private static func lineNumber(in token: Substring, prefix: Character) -> Int? {
        guard token.first == prefix else { return nil }
        let number = token.dropFirst().prefix { $0 != "," }
        return Int(number)
    }

    private static func parseDiffHeader(_ line: String) -> (old: String?, new: String?) {
        let payload = String(line.dropFirst("diff --git ".count))
        let paths = gitTokens(payload)
        guard paths.count >= 2 else { return (nil, nil) }
        return (normalizedPatchPath(paths[0]), normalizedPatchPath(paths[1]))
    }

    private static func parsePathHeader(_ line: String, prefix: String) -> String? {
        let payload = String(line.dropFirst(prefix.count))
        guard let first = gitTokens(payload).first else { return nil }
        return normalizedPatchPath(first)
    }

    private static func normalizedPatchPath(_ path: String) -> String? {
        let decoded = decodeGitPath(path)
        guard decoded != "/dev/null" else { return nil }
        if decoded.hasPrefix("a/") || decoded.hasPrefix("b/") {
            return String(decoded.dropFirst(2))
        }
        return decoded
    }

    private static func gitTokens(_ input: String) -> [String] {
        var tokens: [String] = []
        var token = ""
        var isQuoted = false
        var isEscaped = false

        for character in input {
            if isEscaped {
                token.append("\\")
                token.append(character)
                isEscaped = false
            } else if character == "\\", isQuoted {
                isEscaped = true
            } else if character == "\"" {
                isQuoted.toggle()
                token.append(character)
            } else if character.isWhitespace, !isQuoted {
                if !token.isEmpty {
                    tokens.append(token)
                    token = ""
                }
            } else {
                token.append(character)
            }
        }
        if isEscaped { token.append("\\") }
        if !token.isEmpty { tokens.append(token) }
        return tokens
    }

    private static func decodeGitPath(_ path: String) -> String {
        var source = Array(path.utf8)
        if source.first == 0x22, source.last == 0x22, source.count >= 2 {
            source.removeFirst()
            source.removeLast()
        }
        var decoded: [UInt8] = []
        var index = 0
        while index < source.count {
            guard source[index] == 0x5C, index + 1 < source.count else {
                decoded.append(source[index])
                index += 1
                continue
            }
            let next = source[index + 1]
            if (0x30...0x37).contains(next) {
                var value = 0
                var digits = 0
                var cursor = index + 1
                while cursor < source.count, digits < 3, (0x30...0x37).contains(source[cursor]) {
                    value = value * 8 + Int(source[cursor] - 0x30)
                    cursor += 1
                    digits += 1
                }
                decoded.append(UInt8(clamping: value))
                index = cursor
            } else {
                switch next {
                case 0x6E: decoded.append(0x0A)
                case 0x72: decoded.append(0x0D)
                case 0x74: decoded.append(0x09)
                default: decoded.append(next)
                }
                index += 2
            }
        }
        return String(decoding: decoded, as: UTF8.self)
    }
}

private struct DiffFileBuilder {
    var oldPath: String?
    var newPath: String?
    var kind: UnifiedDiffFileKind = .modified
    var lines: [UnifiedDiffLine] = []
    var additions = 0
    var deletions = 0

    mutating func append(
        _ text: String,
        kind: UnifiedDiffLineKind,
        oldLineNumber: Int? = nil,
        newLineNumber: Int? = nil
    ) {
        lines.append(UnifiedDiffLine(
            kind: kind,
            text: text,
            oldLineNumber: oldLineNumber,
            newLineNumber: newLineNumber
        ))
    }

    mutating func resolveKindAndPath() {
        if oldPath == nil, newPath != nil, kind == .modified {
            kind = .added
        } else if newPath == nil, oldPath != nil, kind == .modified {
            kind = .deleted
        } else if oldPath != nil, newPath != nil, oldPath != newPath, kind == .modified {
            kind = .renamed
        }
    }

    func makeFile(id: Int) -> UnifiedDiffFile {
        let resolvedPath = newPath ?? oldPath ?? "未命名改动 \(id + 1)"
        return UnifiedDiffFile(
            id: id,
            path: resolvedPath,
            oldPath: oldPath,
            newPath: newPath,
            kind: kind,
            lines: lines,
            additions: additions,
            deletions: deletions,
            rawPatch: lines.map(\.text).joined(separator: "\n")
        )
    }
}
