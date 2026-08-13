import Foundation

enum TaskDeliveryEvidenceParser {
    static let marker = "codexboard-evidence"

    static func parse(from result: String) -> TaskDeliveryEvidence {
        if let decoded = decodeMarkedBlock(in: result) {
            return normalized(decoded)
        }
        return TaskDeliveryEvidence(summary: fallbackSummary(from: result))
    }

    static func humanReadableResult(from result: String) -> String {
        let opening = "```\(marker)"
        guard let openingRange = result.range(of: opening, options: .backwards) else {
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let prefix = result[..<openingRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.isEmpty ? fallbackSummary(from: result) : prefix
    }

    private static func decodeMarkedBlock(in result: String) -> TaskDeliveryEvidence? {
        let opening = "```\(marker)"
        guard let openingRange = result.range(of: opening, options: .backwards) else { return nil }
        let remaining = result[openingRange.upperBound...]
        guard let closingRange = remaining.range(of: "```") else { return nil }
        let block = remaining[..<closingRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstBrace = block.firstIndex(of: "{"),
              let lastBrace = block.lastIndex(of: "}"),
              firstBrace <= lastBrace
        else { return nil }
        let json = String(block[firstBrace...lastBrace])
        return try? JSONDecoder().decode(TaskDeliveryEvidence.self, from: Data(json.utf8))
    }

    private static func normalized(_ evidence: TaskDeliveryEvidence) -> TaskDeliveryEvidence {
        TaskDeliveryEvidence(
            summary: evidence.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            changedFiles: normalizedList(evidence.changedFiles),
            artifacts: normalizedArtifacts(evidence.artifacts),
            verificationCommands: normalizedList(evidence.verificationCommands),
            testSummary: evidence.testSummary.trimmingCharacters(in: .whitespacesAndNewlines),
            commitSHA: normalizedOptional(evidence.commitSHA),
            pullRequestURL: normalizedOptional(evidence.pullRequestURL),
            residualRisks: normalizedList(evidence.residualRisks)
        )
    }

    private static func normalizedList(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, seen.insert(clean).inserted else { return nil }
            return clean
        }
    }

    private static func normalizedArtifacts(_ artifacts: [TaskDeliveryArtifact]) -> [TaskDeliveryArtifact] {
        var seen = Set<String>()
        return artifacts.compactMap { artifact in
            let path = artifact.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, seen.insert(path).inserted else { return nil }
            let providedTitle = artifact.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackTitle = URL(fileURLWithPath: path).lastPathComponent
            let kind = artifact.kind.trimmingCharacters(in: .whitespacesAndNewlines)
            return TaskDeliveryArtifact(
                title: providedTitle.isEmpty ? fallbackTitle : providedTitle,
                path: path,
                kind: kind.isEmpty ? "other" : kind
            )
        }
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    private static func fallbackSummary(from result: String) -> String {
        let clean = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > 1_200 else { return clean }
        return "\(clean.prefix(1_200))…"
    }
}
