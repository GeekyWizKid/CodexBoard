import Darwin
import Foundation

struct SSHHostDiscoveryService: Sendable {
    private let configURL: URL
    private let homeDirectory: URL
    private let maximumIncludeDepth: Int

    init(
        configURL: URL? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        maximumIncludeDepth: Int = 8
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.configURL = (configURL ?? homeDirectory
            .appendingPathComponent(".ssh", isDirectory: true)
            .appendingPathComponent("config"))
            .standardizedFileURL
        self.maximumIncludeDepth = max(0, maximumIncludeDepth)
    }

    func discoverHosts() -> [String] {
        var state = DiscoveryState()
        Self.parseConfig(
            at: configURL,
            homeDirectory: homeDirectory,
            maximumIncludeDepth: maximumIncludeDepth,
            depth: 0,
            state: &state
        )
        return state.hosts
    }

    private struct DiscoveryState {
        var hosts: [String] = []
        var seenHosts: Set<String> = []
        var visitedConfigPaths: Set<String> = []

        mutating func appendHost(_ host: String) {
            guard seenHosts.insert(host).inserted else { return }
            hosts.append(host)
        }
    }

    private static func parseConfig(
        at requestedURL: URL,
        homeDirectory: URL,
        maximumIncludeDepth: Int,
        depth: Int,
        state: inout DiscoveryState
    ) {
        guard let configURL = readableFileURL(requestedURL) else { return }
        let canonicalPath = configURL.path
        guard state.visitedConfigPaths.insert(canonicalPath).inserted else { return }

        guard let data = try? Data(contentsOf: configURL, options: .mappedIfSafe),
              let contents = String(data: data, encoding: .utf8)
        else { return }

        for line in contents.components(separatedBy: .newlines) {
            guard let directive = parseDirective(line) else { continue }

            switch directive.keyword.lowercased() {
            case "host":
                for host in directive.arguments where isConcreteHostAlias(host) {
                    state.appendHost(host)
                }

            case "include" where depth < maximumIncludeDepth:
                // Only Include operands can cause another file read. In
                // particular, IdentityFile and every other path directive are
                // deliberately ignored so discovery never opens SSH keys.
                for pattern in directive.arguments {
                    for includeURL in resolveIncludes(
                        pattern,
                        relativeTo: configURL,
                        homeDirectory: homeDirectory
                    ) {
                        parseConfig(
                            at: includeURL,
                            homeDirectory: homeDirectory,
                            maximumIncludeDepth: maximumIncludeDepth,
                            depth: depth + 1,
                            state: &state
                        )
                    }
                }

            default:
                continue
            }
        }
    }

    private static func readableFileURL(_ url: URL) -> URL? {
        let canonicalURL = url
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: canonicalURL.path,
            isDirectory: &isDirectory
        ), !isDirectory.boolValue
        else { return nil }
        return canonicalURL
    }

    private static func parseDirective(
        _ line: String
    ) -> (keyword: String, arguments: [String])? {
        var index = line.startIndex
        while index < line.endIndex, line[index].isWhitespace {
            index = line.index(after: index)
        }
        guard index < line.endIndex, line[index] != "#" else { return nil }

        let keywordStart = index
        while index < line.endIndex {
            let character = line[index]
            if character.isWhitespace || character == "=" || character == "#" {
                break
            }
            index = line.index(after: index)
        }
        guard keywordStart != index else { return nil }
        let keyword = String(line[keywordStart..<index])

        while index < line.endIndex, line[index].isWhitespace {
            index = line.index(after: index)
        }
        if index < line.endIndex, line[index] == "=" {
            index = line.index(after: index)
            while index < line.endIndex, line[index].isWhitespace {
                index = line.index(after: index)
            }
        }

        let arguments = tokenizeArguments(line[index...])
        return (keyword, arguments)
    }

    private static func tokenizeArguments(_ input: Substring) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var isEscaped = false

        func appendCurrentToken() {
            guard !current.isEmpty else { return }
            tokens.append(current)
            current.removeAll(keepingCapacity: true)
        }

        for character in input {
            if isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }
            if character == "\\" {
                isEscaped = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                break
            } else if character.isWhitespace {
                appendCurrentToken()
            } else {
                current.append(character)
            }
        }
        if isEscaped {
            current.append("\\")
        }
        appendCurrentToken()
        return tokens
    }

    private static func isConcreteHostAlias(_ alias: String) -> Bool {
        guard !alias.isEmpty,
              !alias.hasPrefix("!"),
              !alias.contains("*"),
              !alias.contains("?"),
              !alias.contains("["),
              !alias.contains("]")
        else { return false }
        return !alias.unicodeScalars.contains { scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
    }

    private static func resolveIncludes(
        _ rawPattern: String,
        relativeTo includingConfigURL: URL,
        homeDirectory: URL
    ) -> [URL] {
        guard !rawPattern.isEmpty else { return [] }
        let sshDirectory = homeDirectory.appendingPathComponent(".ssh", isDirectory: true)
        let expandedPattern = rawPattern.replacingOccurrences(of: "%d", with: homeDirectory.path)

        if expandedPattern == "~" {
            return expandGlob(homeDirectory.path)
        }
        if expandedPattern.hasPrefix("~/") {
            let relativePattern = String(expandedPattern.dropFirst(2))
            return expandGlob(path(relativePattern, relativeTo: homeDirectory))
        }
        // Expanding another user's home would require account lookup and is not
        // needed for the current user's SSH configuration.
        if expandedPattern.hasPrefix("~") {
            return []
        }
        if (expandedPattern as NSString).isAbsolutePath {
            return expandGlob((expandedPattern as NSString).standardizingPath)
        }

        let currentDirectory = includingConfigURL.deletingLastPathComponent()
        let currentMatches = expandGlob(path(expandedPattern, relativeTo: currentDirectory))
        if !currentMatches.isEmpty {
            return currentMatches
        }

        guard currentDirectory.standardizedFileURL.path != sshDirectory.standardizedFileURL.path else {
            return []
        }
        return expandGlob(path(expandedPattern, relativeTo: sshDirectory))
    }

    private static func path(_ relativePath: String, relativeTo directory: URL) -> String {
        ((directory.path as NSString).appendingPathComponent(relativePath) as NSString)
            .standardizingPath
    }

    private static func expandGlob(_ absolutePattern: String) -> [URL] {
        guard (absolutePattern as NSString).isAbsolutePath else { return [] }
        let components = (absolutePattern as NSString).pathComponents
        guard components.first == "/" else { return [] }

        var candidates = [URL(fileURLWithPath: "/", isDirectory: true)]
        for component in components.dropFirst() {
            if containsGlobMetaCharacter(component) {
                var matches: [URL] = []
                for directory in candidates {
                    guard let contents = try? FileManager.default.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: nil,
                        options: []
                    ) else { continue }
                    matches.append(contentsOf: contents.filter {
                        fnmatch(component, $0.lastPathComponent, FNM_PERIOD) == 0
                    })
                }
                candidates = matches.sorted { $0.path < $1.path }
            } else {
                candidates = candidates.map {
                    $0.appendingPathComponent(component)
                }
            }
            if candidates.isEmpty { break }
        }

        var seenPaths: Set<String> = []
        return candidates.compactMap(readableFileURL).filter {
            seenPaths.insert($0.path).inserted
        }
    }

    private static func containsGlobMetaCharacter(_ component: String) -> Bool {
        component.contains("*") || component.contains("?") || component.contains("[")
    }
}
