# Where the data comes from

The app uses no AI to read threads. It reads what the Claude desktop app and
Claude Code already keep on this computer. Every OS-specific path and
command comes from one place, `lib/platform/claude_platform.dart` (see
[Platform layer](#platform-layer)). `<desktop>` below is the Claude desktop
app's data folder and `~/.claude` is Claude Code's:

| OS | `<desktop>` | `~/.claude` |
|---|---|---|
| macOS | `~/Library/Application Support/Claude` | `~/.claude` |
| Linux | `~/.config/Claude` (or `$XDG_CONFIG_HOME/Claude`) | `~/.claude` |
| Windows | `%APPDATA%\Claude` | `%USERPROFILE%\.claude` |

`CLAUDE_CONFIG_DIR` moves `~/.claude`, as it does for Claude Code itself.

| Source | What the app takes from it |
|---|---|
| `<desktop>/claude-code-sessions/**/local_*.json` | One record per Code session: title, folder, transcript id, PRs, SSH host. Archived ones are skipped |
| `~/.claude/projects/<folder>/<id>.jsonl` | The session's transcript: your messages and Claude's replies. `<folder>` is the working directory with each non-alphanumeric character replaced by `-` (older versions replaced only `/` and `.`; both are tried) |
| `~/.claude/projects/ssh-<id>/<id>.jsonl` | The local copy of an SSH session's transcript. The record's `cwd` is a folder on the remote machine, so the usual path doesn't apply |
| `~/.claude/sessions/*.json` | Which sessions are running now, and their names (for sending) |

Only sessions the desktop app knows about appear: sessions started only in a
terminal have no record, and `claude -p` calls Thread Suit makes itself
never show up. Cloud sessions aren't on disk.

### Titles and project names

- **Title:** your own name for the thread, from `titles.json`, wins over
  everything (renaming in Thread Suit never touches Claude's files). Then a
  `rename_thread` call; then the record's `title`, unless
  it's a placeholder ("Local session (from a project)", "Remote control",
  "Untitled..."); then the start of the first message you sent. Remote
  Control project sessions only ever get the placeholder, so they show
  their first message, as the desktop app's own list does. A project
  thread's real title is kept in the cloud and isn't on disk.
- **Project name:** `projects.json` in the app's folder wins, so you can rename
  a project; then the name from the transcript; then the bare `chan_...` id.
  A Remote Control project session's transcript has an `attachment` line with
  the context Claude was given, which includes
  ``Project: "Name" (id: `chan_...`)``. Project names aren't stored anywhere
  else on disk: the desktop app's IndexedDB and Local Storage don't hold them.

Project threads see your messages inside `<wake>` blocks and reply with the
`post_message` tool. Sessions started on this computer over Remote Control
from a project reply with `mcp__claude-code-remote__send_message` instead;
only calls with `visibility: "posted_to_shared_channel"` reach the thread, so
only those count (`"sent_to_shared_agent"` is a note to the project's
assistant). Those reports aren't what the thread shows: the project's
assistant posts its own rewrite, which is never stored locally. So they're
kept with `kind: "notes"` and shown as "Working notes from this computer"
(muted, collapsed to 3 lines), while `post_message` replies stay normal
(`kind` `reply`). The parser (`lib/services/transcript_parser.dart`) takes all of
these, plus `rename_thread` and `set_thread_resolved`. Plain Code sessions
contribute your prompts and Claude's text. These formats are undocumented, so
a Claude update can break parsing. When the parser
changes what it keeps, it bumps `TranscriptState.version` (`parser_v` in each
cache entry), and older entries are re-read from the start.

## Links

No provider is known or special-cased. Each transcript collects, generically
(`TranscriptState`, newest last, capped):

| Field | What | Cap |
|---|---|---|
| `urls` | http(s) URLs in messages and in MCP and plugin tool calls and results | 40 |
| `shell_urls` | URLs in the output of other shell commands (only Haiku sees these) | 40 |
| `tool_calls` | one line per MCP or plugin call (`name {args}`, 200 chars) and shell command (`$ cmd`) | 20 |
| `refs` | ID-like references in messages: `owner/repo#5`, `#123`, `ABC-12` | 30 |
| `tool_names` | MCP and plugin tool names used | 100 |
| `read_commands` | read-only commands run, as permission rules (`Bash(gh pr view *)`) | 20 |

Left out, so URLs inside files don't become links: the Read, Write, Edit
and other file tools, and shell lines where any command reads, searches or
builds local files, or is an interpreter (`TranscriptState.localCommands`:
`cat`, `grep`, `head`, `sed`, `python3`, `flutter`, `git diff`...). Lines are
split respecting quotes and backslashes (`TranscriptState.splitShell`), so
`flutter test | grep "a|b"` is two commands, not three; `cd` and `export`
don't count either way. Command rules are learned from every remote command,
even in lines whose output doesn't count. Shell keywords
and loops (`while`, `for`, `do`) never become command rules. The project
thread and Remote Control tools carry messages and are read as messages.
The `prs` the desktop app records in a session's JSON are added as
references.

`LinkService` turns a thread's `LinkDigest` (those fields, merged across the
thread's sessions, at most 12,000 characters) into links with one Haiku call
(`ClaudeCli.resolveLinks`). It runs `claude -p --model haiku --output-format
json --tools Bash|"" --disable-slash-commands --allowedTools ...`, with only
read-only tools allowed (`ClaudeCli.linkLookupTools`): MCP and plugin tools
seen in this computer's sessions whose names start with a read verb (`get`,
`view`, `read`, `fetch`, `search`, `list`, `find`, `show`, `query`,
`lookup`, `describe`, `retrieve`), plus the `read_commands`. It has no file
tools. It runs with `--output-format stream-json --verbose`, so Thread Suit
sees the text of every tool result in the run. The answer is a JSON array of
`{kind, provider_name, key, title, state, url, label}`. Its URLs aren't
trusted (`LinkDetector.validate`): a link is kept only if it's `https` and its
exact URL (ignoring scheme, `www.`, trailing slash, query and fragment)
appears in the digest or in those tool results. Its provider name, key, title
and state are taken as given; the prompt tells Haiku not to guess and to
leave them null, or return `[]`, when it doesn't know. The link text is built
from those parts: provider, then `PR` (or `MR`) for pull requests, then the
key (`#` added to a bare number), then `: title`, e.g. "GitHub PR #20: Fix
login" or "YouTrack OPS-4: Build the data model". `label` supplies the
provider's casing (when it matches `provider_name`) and the PR/MR word.

When it runs: the digest's hash covers URLs, references and MCP calls (not
ordinary shell commands). A changed hash waits 30 seconds to settle, then
the thread is looked up, at most once every 10 minutes per thread, one
thread at a time, at most once a minute overall. A thread with an empty
digest, or one with no evidence (`LinkDigest.hasEvidence`: no URL off this
computer and the local network, and no connector, plugin or CLI call), is
never looked up. `"resolve_links": false` in `config.json`, or
`THREAD_SUIT_RESOLVE_LINKS=0`, turns lookups off. Without a result, a thread
shows its plain `urls`, minus local and private addresses, assets and bare
hosts.


## App files in `~/.thread-suit/`

`THREAD_SUIT_DIR` moves this folder (`THREAD_DASHBOARD_DIR`, from before the
rename, still works). `THREAD_SUIT_RESOLVE_LINKS=0` turns link lookups off,
like `"resolve_links": false` in `config.json`.

On first start, an existing `~/.thread-dashboard/` (the app's old name) is
moved here. If it can't be moved, it's copied and the old folder is left.

| File | Purpose |
|---|---|
| `cache.json` | Parsed transcript state (messages, URLs, tool calls, references, titles) and read offsets, so only new bytes are read |
| `seen.json` | When you last looked at each thread, for unread dots |
| `sleep.json` | Threads you put to sleep, keyed to the newest message you'd seen |
| `ui.json` | `{"theme": "light"}` or `"dark"`, from the title bar switch; no key means follow the system |
| `titles.json` | Your own names for threads (thread id to name), set with the pencil next to a title |
| `links.json` | Per thread: the digest hash, the links Haiku found (or `failed`), when, and what it cost |
| `config.json` | Optional: `{"resolve_links": false}` turns Haiku link lookups off |
| `projects.json` | Project id to name (transcripts only carry the id) |
| `outbox/<id>.json` | A message waiting to be delivered |

## AI use

- **Sending:** one `claude -p --model haiku` call per message, using the
  `SendMessage` tool to reach the thread's running session. If the session
  isn't running, the message waits in `outbox/`; checking that is local and
  makes no Claude call. A send that fails is tried at most 3 times, 1 and then
  5 minutes apart, then left in `outbox/` marked not sent
  (`SendService.maxTries`).
- **Links:** one Haiku call per lookup, as described in [Links](#links).
  Measured on real threads: 17k to 80k input tokens (mostly Claude Code's own
  instructions and tool list, largely cached, plus tool results) and 1 to 3k
  output tokens, roughly 1 to 3 cents per lookup. `links.json` records each lookup's cost.

## Instant refresh

The app listens on `http://127.0.0.1:47321/changed` (loopback only). Global
Claude Code hooks in `~/.claude/settings.json` POST there on
`UserPromptSubmit`, `Stop`, and `PostToolUse` for `post_message`,
`rename_thread`, `set_thread_resolved` and `claude-code-remote__send_message`:

```json
{"type": "command", "async": true, "timeout": 3,
 "command": "curl -s -m 1 -X POST http://127.0.0.1:47321/changed >/dev/null 2>&1 || true"}
```

Install or remove them with `python3 tools/install_hook.py [--uninstall]`.
The installer keeps your other settings and hooks, writes
`settings.json.bak` first, is safe to run again, and upgrades an older copy
of Thread Suit's hooks in place. It finds `settings.json` the way Claude Code
does: in `$CLAUDE_CONFIG_DIR`, otherwise `~/.claude` (`%USERPROFILE%\.claude`
on Windows), and reads and writes it as UTF-8. A settings file it can't parse
is left untouched. On Windows, Claude Code runs hook commands in Git Bash
(it says so itself when Git Bash is missing), so the same `curl ... || true`
command works there; Git for Windows includes `curl`. Without Git Bash,
Claude Code reports an error for the hook instead of running it. Tests:
`python3 -m unittest discover -s tools -p 'test_*.py'`.
A ping makes the app re-read transcripts immediately (and once more a second
later, in case the line wasn't written yet). Without the hooks, the app still
polls every 15 seconds. When the app isn't running, the hook's `curl` is
refused immediately, and `|| true` makes it exit 0, so Claude Code is not
affected. Only Claude Code running on this computer can ping: SSH sessions run
Claude Code on the remote machine, and cloud threads have none locally, so
they rely on polling. Sessions started before the hooks were installed need
a restart to load them.

## Platform layer

`lib/platform/claude_platform.dart` has an abstract `ClaudePlatform` with
`MacOSPlatform`, `LinuxPlatform` and `WindowsPlatform`. `ClaudePlatform.current`
is picked once from the running OS; nothing else in `lib/` checks the OS. Each
implementation provides:

| | macOS | Linux | Windows |
|---|---|---|---|
| Desktop data | `~/Library/Application Support/Claude` | `$XDG_CONFIG_HOME/Claude`, `~/.config/Claude` | `%APPDATA%\Claude` |
| Home | `$HOME` | `$HOME` | `%USERPROFILE%` |
| `claude` binary | `~/.local/bin/claude`, else `PATH` | same | `~\.local\bin\claude.exe`, else `PATH` |
| Added to `PATH` for tools | `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin` | `~/.local/bin`, `/home/linuxbrew/.linuxbrew/bin`, `/usr/local/bin`, `/snap/bin` | `~\.local\bin` |
| Open a URL | `open` | `xdg-open` | `rundll32 url.dll,FileProtocolHandler` |
| Is a process running | `kill -0` | `kill -0` | `tasklist /FI "PID eq N"` |
| Send shortcut | ⌘↩ | Ctrl+Enter | Ctrl+Enter |

`ClaudePlatform.forOS(os, env: ..., fileExists: ...)` builds any of them with a
fake environment, so `test/platform_test.dart` checks all three on any
machine. `buildRootInjector(dir, platform)` and the services take one too.

## App icons

All icons come from `docs/Icon.png`; `tools/generate_icons.py` (Pillow) writes
them. It crops the artwork to its visible pixels and centres it: on macOS at
824 of 1024 pixels (Apple's icon grid), elsewhere at 92% of the square.

| OS | Files | Used by |
|---|---|---|
| macOS | `macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{16..1024}.png` | the app bundle |
| Windows | `windows/runner/resources/app_icon.ico` (16 to 256) | the `.exe` and its window |
| Linux | `linux/runner/resources/app_icon.png` (256) | the window icon: `linux/CMakeLists.txt` installs it as `bundle/data/app_icon.png` and `linux/runner/my_application.cc` loads it |
| Linux | `linux/packaging/icons/hicolor/<n>x<n>/apps/io.github.bryangwalsh.thread_suit.png` (16 to 512), `linux/packaging/io.github.bryangwalsh.thread_suit.desktop` | app menu and dock, after `linux/packaging/install.sh` |

The desktop entry's name matches the app id and `StartupWMClass`
(`io.github.bryangwalsh.thread_suit`), so desktops match the running window
to it.

