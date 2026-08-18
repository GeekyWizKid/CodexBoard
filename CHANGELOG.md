# Changelog

CodexBoard follows [Semantic Versioning](https://semver.org/) for public releases.

## [Unreleased]

### Added

- Unified management for the local Mac and multiple headless Codex hosts over
  system SSH, including per-host projects, connection state, concurrency, and
  reconnect reconciliation through `thread/read`.
- A guided three-step SSH host setup flow with discoverable aliases and
  copyable install, device-auth, and non-interactive verification commands.
- GPT Live voice/text requirement capture with editable drafts, explicit
  confirmation before task creation, macOS Keychain storage, and an isolated
  local Realtime child process.

### Security

- Remote paths are inspected only on their owning host; SSH credentials and
  Codex auth files are never copied or persisted by CodexBoard.
- Remote tasks reject Mac-local worktrees and attachments, and ambiguous
  reconnect state stops for attention instead of starting duplicate work.

### Planned

- Developer ID signing and Apple notarization for public distribution.
- A stable production bundle identifier and release update channel.

## [0.1.1] — 2026-08-14

### Changed

- Runtime approval menus now mirror the current Codex app-server decision
  model: allow once, remember for the task session, remember an exact command
  prefix, remember a network-host rule, or deny while continuing/stopping.
- File-change approvals can be remembered for the current task, and precise
  permission requests can be granted for one turn, for the task session, or
  for one turn with strict command review.

### Fixed

- Structured exec-policy and network-policy decisions are no longer discarded
  when parsing `availableDecisions` from newer Codex app-server versions.
- Legacy approval requests derive only the choices supported by their command,
  network, or additional-permission context.

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

[Unreleased]: https://github.com/GeekyWizKid/CodexBoard/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/GeekyWizKid/CodexBoard/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/GeekyWizKid/CodexBoard/releases/tag/v0.1.0
