# CodexBoard Brand and Localization QA

Reference: selected Task Signal Field concept, generated icon, and bilingual campaign artwork.

## Visual comparison

- Final icon preserves the selected three-lane workflow mark and amber approval gate.
- 32 px inspection remains legible with a distinct amber gate and three indigo lanes.
- English and Simplified Chinese campaign images keep the same composition, palette, app-window hierarchy, and proof-point structure.
- The signed macOS bundle contains `Assets.car`, `AppIcon.icns`, and both localization folders.

## Product verification

- English launch: core board stages, actions, search, empty inspector, and relative dates switch to English.
- Simplified Chinese launch: core board stages, actions, search, empty inspector, and relative dates switch to Chinese.
- Language preference supports Follow System, Simplified Chinese, and English; QA restored it to Follow System.
- Existing Codex output, project names, paths, model names, Skill names, and App names remain unmodified.
- Notification copy uses the selected application language while retaining the privacy-safe payload boundary.

## Remaining notes

- Persisted historical activity and task runtime messages may remain in the language used when they were created; common live states are translated at display time.
- The app remains ad-hoc signed and is not a notarized public release, as stated in both READMEs.

final result: passed
