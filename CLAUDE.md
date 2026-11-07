# Notes for Claude working on Thread Suit

- **Cross-platform:** the app runs on macOS, Linux and Windows. OS differences
  (paths, opening URLs, finding `claude`, checking processes, shortcut keys)
  go in `lib/platform/claude_platform.dart` only, with a test for each OS in
  `test/platform_test.dart`. Nothing else in `lib/` checks the OS.
- **Test on the real machine:** run and test on the computer whose Claude
  sessions you want to see, not in a cloud container. The app only works
  against the real local session files.
- **State management** uses `complete_dependency_injector_flutter` (by the
  project author). Services are provided in `buildRootInjector` in
  `lib/main.dart`, and the UI reads them through `DashboardViewModel` and
  `DependenciesBuilder`. Keep new state in services, exposed as
  `BehaviorSubject` streams.
- **File formats:** data sources and file formats are in
  [docs/FILE_FORMAT.md](docs/FILE_FORMAT.md). The transcript and session
  formats are undocumented Claude internals. If a Claude update breaks the
  list, start with `lib/services/transcript_parser.dart` and the scan check
  (`SNAPSHOT_DIR=~/.thread-suit flutter test tool_test/scan_check_test.dart`).
- **Parser changes:** when the parser changes what it keeps, bump
  `TranscriptState.version` so cached transcripts are re-read.
- **App state** lives in `~/.thread-suit/` (`seen.json`, `sleep.json`,
  `titles.json`, `ui.json`, `links.json`, `cache.json`, `projects.json`, `config.json`,
  `outbox/`). Never write to Claude's own files.
  `cache.json` can be deleted safely; it is rebuilt on the next scan.
- **Minimal AI use:** no long-running sync session. Reading is free. Sending
  and link lookups (rate-limited, cached, read-only tools only) use one-off
  Haiku `claude -p` calls
  (`lib/services/claude_cli.dart`).
- **Links are generic:** no provider-specific code (no GitHub, Jira, ...
  special cases). `TranscriptState` collects URLs, tool calls and references;
  `LinkService` sends a thread's digest to one Haiku call
  (`ClaudeCli.resolveLinks`) with read-only tools only, and keeps only https
  links whose exact URL appears in the thread or Haiku's tool results (titles
  and states are taken as Haiku gives them). Threads without evidence are
  never looked up. To improve links, change the digest,
  the prompt or the validation, and `test/link_detector_test.dart`. Keep
  lookups rare (debounce, per-thread interval, cache); a lookup costs a few
  cents. `tool_test/resolve_check_test.dart` runs one real lookup.
- **`send_check_test`:** `tool_test/send_check_test.dart` sends a real message
  to a running thread. Only run it when the user asks you to.
- **Icons:** generated from `docs/Icon.png` by `tools/generate_icons.py`;
  don't edit the generated files by hand (see docs/FILE_FORMAT.md).
- **Checks:** run `flutter analyze` and `flutter test` before calling a
  change done.
