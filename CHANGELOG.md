# Changelog

CodexBoard follows [Semantic Versioning](https://semver.org/) for public releases.

## [Unreleased]

### Added

- Apache License 2.0 project licensing, third-party notices, and separate
  trademark guidelines for the CodexBoard name and visual identity.

### Planned

- Developer ID signing and Apple notarization for public distribution.
- A stable production bundle identifier and release update channel.

## [0.1.0] — 2026-08-13

### Added

- Local-first multi-project kanban backed by the local Codex app-server.
- Manual or automatic read-only planning, editable plan approval, execution queueing, and delivery review.
- Task-scoped model, reasoning effort, and Fast service-tier selection.
- Isolated Git worktree execution, dependency handoffs, controlled concurrency, and failure circuit breaking.
- Local Skills and read-only Apps, MCP/OAuth connections, and human-in-the-loop command, file, permission, user-input, and elicitation flows.
- Approval attention that opens, scrolls to, and highlights the relevant task card, with privacy-safe macOS notifications.
- Structured delivery evidence, artifacts, per-file change summaries, and unified diff review.
- English and Simplified Chinese interfaces with system-following or explicit language selection.
- Final application icon, bilingual README landing pages, and bilingual campaign artwork.

### Security

- Planning remains read-only and offline.
- Auto-run never approves runtime interactions automatically.
- Pending interactions and secret answers remain in memory and are not persisted.
- Notification payloads include only a task UUID and generic copy.
- Dirty or unmanaged worktrees are never force-deleted.

[Unreleased]: https://github.com/GeekyWizKid/CodexBoard/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/GeekyWizKid/CodexBoard/releases/tag/v0.1.0
