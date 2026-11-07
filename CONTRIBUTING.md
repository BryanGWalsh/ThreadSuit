# Contributing to Thread Suit

Issues and pull requests are welcome at
[github.com/BryanGWalsh/ThreadSuit](https://github.com/BryanGWalsh/ThreadSuit).
Bug reports, Windows test drives, and fixes for the next time Claude
rearranges its files are all very welcome.

How the app reads Claude's data, finds links and handles each OS is in
[docs/FILE_FORMAT.md](docs/FILE_FORMAT.md). If you work on Thread Suit with
Claude Code, [CLAUDE.md](CLAUDE.md) has notes for Claude.

## House rules

A few rules to keep the stitching straight:

- **Keep it cross-platform:** OS-specific code goes in
  `lib/platform/claude_platform.dart` only, with a test for each OS in
  `test/platform_test.dart`. Nothing else in `lib/` checks the OS.
- **Keep AI use minimal:** reading threads must stay free. New features
  shouldn't add `claude -p` calls without a good reason.
- **No provider-specific code:** links stay generic. Don't add special cases
  for GitHub, Jira or anyone else; improve the summary, the prompt or the
  checks instead (`lib/services/link_service.dart`,
  `lib/services/claude_cli.dart`, `lib/services/link_detector.dart`).
- **Never write to Claude's files:** Thread Suit only reads them, and keeps
  its own state in `~/.thread-suit/`.

## Building

Flutter's own setup guide covers each OS. A few things worth knowing:

- **Linux:** the build needs Flutter's Linux toolchain. On Ubuntu or Debian:
  `sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libstdc++-12-dev`.
  `linux/packaging/install.sh` installs a release build for your user (app
  menu entry and icons, no `sudo`); `--uninstall` removes it.
- **Windows:** needs Visual Studio 2022 with "Desktop development with C++".
  Nobody has run Thread Suit on Windows yet, so reports are very welcome.
- **macOS:** the app sandbox is off on purpose (`macos/Runner/*.entitlements`):
  Thread Suit has to read `~/Library/Application Support/Claude` and
  `~/.claude`, and run `claude`.

## Checks

Run these before opening a PR:

```bash
flutter analyze
flutter test
python3 -m unittest discover -s tools -p 'test_*.py'   # the hook installer
```

Some checks need your real Claude data, so they aren't part of `flutter test`:

```bash
# Scan your sessions and print the newest threads
SNAPSHOT_DIR=~/.thread-suit flutter test tool_test/scan_check_test.dart

# Run one real link lookup for a thread and print what it found and cost
SNAPSHOT_DIR=~/.thread-suit TITLE='part of a title' flutter test tool_test/resolve_check_test.dart

# Render a screenshot of the app, with your real threads, to a PNG
SNAPSHOT_DIR=~/.thread-suit OUT=/tmp/shot.png flutter test tool_test/screenshot_test.dart
```

`tool_test/send_check_test.dart` sends a real message to a running thread
(`SESSION=local_… TEXT='…'`), so only run it when you mean it.

## Screenshots and icons

The README screenshots use made-up threads only (a fake home folder, never
your real sessions). To render them again:

```bash
flutter test tool_test/readme_screenshot_test.dart
THEME=dark flutter test tool_test/readme_screenshot_test.dart
```

They come out at about 650 KB; shrink them to a 256-colour palette (about
220 KB) before committing.

The app icons for all three platforms come from `docs/Icon.png`. After
changing it, regenerate them (needs Pillow: `pip install pillow`):

```bash
python3 tools/generate_icons.py
```

## Running from Android Studio or IntelliJ

Two shared run configurations are in `.run/`: **Thread Suit** (debug, with
hot reload) and **Thread Suit (release)**. Pick a desktop device in the
device menu and press Run. If none is listed, run
`flutter config --enable-linux-desktop` (or `--enable-macos-desktop`,
`--enable-windows-desktop`) and restart the IDE.
