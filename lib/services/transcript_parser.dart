import 'dart:convert';
import 'dart:io';

import 'link_detector.dart';

/// What one Claude Code transcript (`~/.claude/projects/*/<id>.jsonl`) says
/// about its conversation. Built incrementally: [readFrom] parses only the
/// bytes appended since the last call.
///
/// Project threads see your messages inside `<wake>` blocks and reply with the
/// `post_message` tool. Plain Code sessions have ordinary user prompts and
/// assistant text. Both formats are undocumented, so parsing is defensive.
class TranscriptState {
  int offset = 0;
  String? threadId;
  String? projectId;
  String? renamedTitle;

  /// The project's name, from the context Claude gets in a Remote Control
  /// project session (`Project: "Name" (id: `chan_…`)`).
  String? projectName;

  /// The start of the first message you sent, used as the title when the
  /// session has no better one.
  String? firstPrompt;
  bool? resolved;
  bool isProjectThread = false;
  final List<ParsedMessage> messages = [];

  // What the conversation touched, for finding its PRs and issues. Nothing
  // here knows any provider: it's URLs, tool calls and ID-like references as
  // they are. File reads, edits and searches are skipped, so URLs inside
  // files don't count. Each list is newest last and capped.

  /// URLs in messages and in connector or plugin (MCP) tool calls and results.
  final List<String> urls = [];

  /// URLs in the output of other shell commands. Only Haiku sees these; they
  /// aren't shown as plain links, since build and test output is noisy.
  final List<String> shellUrls = [];

  /// Short lines describing link-relevant tool calls: `mcp__x__get_issue
  /// {"id":"A-1"}` or `$ gh pr view 12`.
  final List<String> toolCalls = [];

  /// ID-like references in messages: `owner/repo#5`, `#123`, `ABC-12`.
  final List<String> refs = [];

  /// Names of the MCP and plugin tools this session used.
  final Set<String> toolNames = {};

  /// Read-only commands this session ran, as permission rules a lookup may
  /// reuse: `Bash(gh pr view *)`.
  final Set<String> readCommands = {};

  static const maxUrls = 40, maxCalls = 20, maxRefs = 30, maxTools = 100;

  /// Ids of tool calls whose results haven't been read yet, and whether each
  /// was a shell command.
  final Map<String, bool> _pendingTools = {};

  static const keep = 12;

  /// Bumped whenever parsing changes what it keeps; cache entries from an
  /// older version are re-read from the start.
  static const version = 10;
  static const maxLinks = 30;

  Map<String, dynamic> toJson() => {
    'offset': offset,
    'thread_id': threadId,
    'project_id': projectId,
    'renamed_title': renamedTitle,
    'project_name': projectName,
    'first_prompt': firstPrompt,
    'resolved': resolved,
    'is_project_thread': isProjectThread,
    'messages': messages.map((m) => m.toJson()).toList(),
    'urls': urls,
    'shell_urls': shellUrls,
    'tool_calls': toolCalls,
    'refs': refs,
    'tool_names': toolNames.toList(),
    'read_commands': readCommands.toList(),
    'pending_tools': _pendingTools,
    'parser_v': version,
  };

  /// A cache entry from an older [version] is re-read from the start.
  static TranscriptState fromJson(Map<String, dynamic> j) => j['parser_v'] != version
      ? TranscriptState()
      : (TranscriptState()
          ..urls.addAll(_strings(j['urls']))
          ..shellUrls.addAll(_strings(j['shell_urls']))
          ..toolCalls.addAll(_strings(j['tool_calls']))
          ..refs.addAll(_strings(j['refs']))
          ..toolNames.addAll(_strings(j['tool_names']))
          ..readCommands.addAll(_strings(j['read_commands']))
          .._pendingTools.addAll({
            for (final e in ((j['pending_tools'] as Map?) ?? const {}).entries)
              if (e.key is String) e.key as String: e.value == true,
          })
          ..offset = j['offset'] as int
          ..threadId = j['thread_id'] as String?
          ..projectId = j['project_id'] as String?
          ..renamedTitle = j['renamed_title'] as String?
          ..projectName = j['project_name'] as String?
          ..firstPrompt = j['first_prompt'] as String?
          ..resolved = j['resolved'] as bool?
          ..isProjectThread = j['is_project_thread'] == true
          ..messages.addAll(
            ((j['messages'] as List?) ?? const []).map((m) => ParsedMessage.fromJson(m as Map<String, dynamic>)),
          ));

  /// Parses complete lines from [offset] to the end of [file].
  void readFrom(File file) {
    final length = file.lengthSync();
    if (length < offset) {
      // Rewritten or truncated: start over.
      offset = 0;
      messages.clear();
      for (final l in [urls, shellUrls, toolCalls, refs]) {
        l.clear();
      }
      toolNames.clear();
      readCommands.clear();
      _pendingTools.clear();
    }
    if (length == offset) return;
    final raf = file.openSync();
    try {
      raf.setPositionSync(offset);
      final bytes = raf.readSync(length - offset);
      final lastNewline = bytes.lastIndexOf(10);
      if (lastNewline < 0) return; // only a partial line so far
      final chunk = utf8.decode(bytes.sublist(0, lastNewline + 1), allowMalformed: true);
      for (final line in const LineSplitter().convert(chunk)) {
        if (line.isNotEmpty) _parseLine(line);
      }
      offset += lastNewline + 1;
    } finally {
      raf.closeSync();
    }
    if (messages.length > keep) messages.removeRange(0, messages.length - keep);
  }

  static final _projectLine = RegExp(r'Project: \\"((?:[^"\\]|\\.)*)\\" \(id: `(chan_\w+)`\)');

  void _parseLine(String line) {
    if (projectName == null && line.contains('(id: `chan_')) {
      final m = _projectLine.firstMatch(line);
      if (m != null) {
        try {
          projectName = jsonDecode('"${m[1]}"') as String;
          projectId ??= m[2];
        } catch (_) {}
      }
    }
    Map<String, dynamic> e;
    try {
      e = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final type = e['type'];
    if (type != 'user' && type != 'assistant') return;
    if (e['isMeta'] == true || e['isSidechain'] == true) return;
    final at = DateTime.tryParse((e['timestamp'] as String?) ?? '');
    final content = (e['message'] as Map?)?['content'];
    if (at == null || content == null) return;

    final texts = <String>[];
    if (content is String) {
      texts.add(content);
    } else if (content is List) {
      for (final b in content) {
        if (b is! Map) continue;
        if (b['type'] == 'text') texts.add((b['text'] as String?) ?? '');
        if (b['type'] == 'tool_use' && type == 'assistant') {
          _toolUse(b, at);
          _noteToolCall(b);
        }
        if (b['type'] == 'tool_result') {
          final shell = _pendingTools.remove(b['tool_use_id']);
          if (shell != null) _addUrls(_resultText(b['content']), shell: shell);
        }
      }
    }

    for (final text in texts) {
      if (type == 'user') {
        if (text.contains('<wake')) {
          isProjectThread = true;
          _wake(text);
        } else if (!isProjectThread && _isPrompt(text)) {
          _add(
            ParsedMessage(id: '${at.microsecondsSinceEpoch}u', fromHuman: true, author: 'You', sentAt: at, text: text),
          );
        }
      } else if (!isProjectThread && text.trim().isNotEmpty) {
        // Plain sessions: assistant text is what you read.
        _add(
          ParsedMessage(
            id: '${at.microsecondsSinceEpoch}a',
            fromHuman: false,
            author: 'Claude',
            sentAt: at,
            text: text,
          ),
        );
      }
    }
  }

  /// Plain-session user text that you typed, not harness or tool output.
  static bool _isPrompt(String t) {
    final s = t.trimLeft();
    return s.isNotEmpty &&
        !s.startsWith('<') &&
        !s.startsWith('[Request interrupted') &&
        !s.startsWith('Caveat:') &&
        !s.startsWith('This session is being continued');
  }

  static final _threadTs = RegExp(r'<thread ts="(cmsg_\w+)"');
  static final _project = RegExp(r'<project id="(chan_\w+)"');
  static final _message = RegExp(r'<message ([^>]*)>([\s\S]*?)</message>');
  static final _attr = RegExp(r'([\w-]+)="([^"]*)"');

  void _wake(String text) {
    projectId ??= _project.firstMatch(text)?.group(1);
    threadId ??= _threadTs.firstMatch(text)?.group(1);
    for (final m in _message.allMatches(text)) {
      final attrs = {for (final a in _attr.allMatches(m.group(1)!)) a.group(1)!: a.group(2)!};
      if (attrs['from'] != 'human') continue;
      final id = attrs['id'];
      final sent = DateTime.tryParse(attrs['sent-at'] ?? '');
      if (id == null || sent == null) continue;
      // The first message of a thread is its root, whose id is the thread id.
      threadId ??= id;
      if (messages.any((x) => x.id == id)) continue;
      _add(
        ParsedMessage(
          id: id,
          fromHuman: true,
          author: _unescape(attrs['author'] ?? 'You'),
          sentAt: sent,
          text: _unescape(m.group(2)!.trim()),
        ),
      );
    }
  }

  void _toolUse(Map b, DateTime at) {
    final name = (b['name'] as String?) ?? '';
    final input = (b['input'] as Map?) ?? const {};
    // Thread sessions post with `post_message`; sessions started over Remote
    // Control from a project reply to it with `claude-code-remote__send_message`
    // (only "posted_to_shared_channel" reaches the thread; "sent_to_shared_agent"
    // is a note to the project's assistant).
    final isRemoteReply =
        name.endsWith('claude-code-remote__send_message') &&
        input['session_id'] == '@parent' &&
        (input['visibility'] ?? 'posted_to_shared_channel') == 'posted_to_shared_channel';
    if (name.endsWith('hearthbot__post_message') || isRemoteReply) {
      isProjectThread = true;
      final text = (input['text'] ?? input['message']) as String?;
      if (text != null) {
        // A Remote Control session's report reaches the thread only as the
        // project assistant's rewrite; what's on disk is the session's notes.
        _add(
          ParsedMessage(
            id: (b['id'] as String?) ?? '$at',
            fromHuman: false,
            author: 'Claude',
            sentAt: at,
            text: text,
            kind: isRemoteReply ? 'notes' : 'reply',
          ),
        );
      }
    } else if (name.endsWith('hearthbot__rename_thread')) {
      renamedTitle = input['title'] as String? ?? renamedTitle;
    } else if (name.endsWith('hearthbot__set_thread_resolved')) {
      if (input['thread_id'] == null) resolved = input['resolved'] == true;
    }
  }

  static Iterable<String> _strings(Object? l) => ((l as List?) ?? const []).whereType<String>();

  /// Programs that read, search or build local files, and interpreters: their
  /// output is file contents or build noise, not the PRs and issues a thread
  /// is about. Not provider-specific: any other command counts.
  static const localCommands = {
    'cat', 'head', 'tail', 'less', 'more', 'bat', 'grep', 'egrep', 'rg', 'ag', 'ack', 'sed', 'awk', 'find', //
    'fd', 'ls', 'tree', 'wc', 'diff', 'sort', 'uniq', 'cut', 'file', 'stat', 'du', 'df', 'echo', 'printf',
    'tee', 'cp', 'mv', 'rm', 'mkdir', 'touch', 'chmod', 'cd', 'pwd', 'python', 'python3', 'node', 'deno',
    'bun', 'ruby', 'perl', 'sh', 'bash', 'zsh', 'dart', 'flutter', 'npm', 'npx', 'yarn', 'pnpm', 'cargo',
    'go', 'make', 'cmake', 'ninja', 'gradle', 'mvn', 'dotnet', 'pip', 'pip3', 'sleep', 'timeout', 'xargs',
    'jq', 'open', 'xdg-open', 'code', 'vim', 'nano', 'test', 'true', 'false',
  };

  /// Commands that don't affect what a line prints.
  static const _neutralCommands = {'cd', 'pushd', 'popd', 'export', 'unset'};

  /// `git` subcommands that print file contents.
  static const _localGit = {'diff', 'show', 'grep', 'blame', 'cat-file', 'apply', 'add', 'checkout', 'restore'};

  /// Shell builtins: never turned into a reusable command rule.
  static const _shellBuiltins = {
    'do', 'done', 'then', 'else', 'fi', 'while', 'until', 'for', 'if', 'case', 'esac', 'read', 'run', 'eval', //
    'exec', 'source', 'export', 'env', 'sudo', 'su', 'nohup', 'xargs', 'command', 'builtin', 'set', 'unset',
    'alias', 'local', 'declare', 'trap', 'kill', 'wait', 'exit', 'return', 'shift', 'select', 'function',
  };

  static final _readVerb = RegExp(r'^(view|show|list|ls|get|status|info|search|describe|read)$');
  static final _plainWord = RegExp(r'^[A-Za-z][\w.-]*$');

  /// Each command in a shell line, as its words (`cd x && gh pr view 1` ->
  /// [[cd, x], [gh, pr, view, 1]]). Heredocs and quoting are not parsed:
  /// only the first line counts.
  static List<List<String>> _commands(String line) => [
    for (final seg in splitShell(line))
      if (_withoutKeywords(seg) case final words when words.isNotEmpty) words,
  ];

  /// Splits a shell line into commands and words, respecting quotes and
  /// backslashes: `a "x|y" | b` is [[a, x|y], [b]]. Commands are separated by
  /// `|`, `||`, `&&`, `;`, `&` and newlines outside quotes. A heredoc's body
  /// is skipped (only the line before it counts).
  static List<List<String>> splitShell(String line) {
    final heredoc = line.indexOf('<<');
    final src = heredoc >= 0
        ? line.substring(0, line.indexOf('\n', heredoc) < 0 ? line.length : line.indexOf('\n', heredoc))
        : line;
    final out = <List<String>>[];
    var words = <String>[];
    final word = StringBuffer();
    var hasWord = false;
    String? quote;
    void endWord() {
      if (hasWord) words.add(word.toString());
      word.clear();
      hasWord = false;
    }

    void endCommand() {
      endWord();
      if (words.isNotEmpty) out.add(words);
      words = <String>[];
    }

    for (var i = 0; i < src.length; i++) {
      final c = src[i];
      if (quote != null) {
        if (c == quote) {
          quote = null;
        } else if (c == '\\' && quote == '"' && i + 1 < src.length) {
          word.write(src[++i]);
        } else {
          word.write(c);
        }
        continue;
      }
      if (c == "'" || c == '"') {
        quote = c;
        hasWord = true;
      } else if (c == '\\' && i + 1 < src.length) {
        word.write(src[++i]);
        hasWord = true;
      } else if (c == ' ' || c == '\t') {
        endWord();
      } else if (c == '&' && ((i > 0 && src[i - 1] == '>') || (i + 1 < src.length && src[i + 1] == '>'))) {
        word.write(c); // a redirection: 2>&1, &>
        hasWord = true;
      } else if (c == '|' || c == ';' || c == '&' || c == '\n') {
        endCommand();
      } else if (c == '<' && i + 1 < src.length && src[i + 1] == '<') {
        endWord();
        break; // heredoc: the rest is its body
      } else {
        word.write(c);
        hasWord = true;
      }
    }
    endCommand();
    return out;
  }

  /// Shell keywords that start a segment without being its program
  /// (`do gh pr view 1` runs `gh`), dropped from the front. A segment that
  /// starts with `while`, `for`, `if` or `case` is a loop or condition, not
  /// one command, so it's dropped whole.
  static const _leadingKeywords = {'do', 'then', 'else', 'time', '{', '(', '!'};
  static const _compoundKeywords = {
    'while',
    'until',
    'for',
    'if',
    'elif',
    'case',
    'select',
    'function',
    'done',
    'fi',
    'esac',
    '}',
    ')',
  };

  static List<String> _withoutKeywords(List<String> words) {
    var w = words;
    while (w.isNotEmpty && _leadingKeywords.contains(w.first)) {
      w = w.sublist(1);
    }
    if (w.isEmpty || _compoundKeywords.contains(w.first) || w.first.contains('=')) return const [];
    return w;
  }

  /// Whether a shell command's output can name what the thread works on.
  static bool _isRemoteCommand(List<String> words) {
    final prog = words.first.split('/').last;
    if (localCommands.contains(prog) || !_plainWord.hasMatch(prog)) return false;
    if (prog == 'git') return words.length > 1 && !_localGit.contains(words[1]);
    return true;
  }

  /// Notes a tool call's name, a short summary of it, and the URLs in its
  /// input; its result is read when it arrives.
  void _noteToolCall(Map b) {
    final name = (b['name'] as String?) ?? '';
    final id = b['id'];
    final input = (b['input'] as Map?) ?? const {};
    if (name.startsWith('mcp__')) {
      // Project-thread and Remote Control tools carry messages, read as such.
      if (name.contains('hearthbot__') || name.contains('claude-code-remote__')) return;
      if (toolNames.length < maxTools) toolNames.add(name);
      final args = jsonEncode(input);
      _addCall('$name ${args.length > 200 ? '${args.substring(0, 199)}…' : args}');
      _addUrls(args, shell: false);
      if (id is String) _pend(id, shell: false);
    } else if (name == 'Bash') {
      final line = (input['command'] as String?) ?? '';
      final commands = _commands(line).where((w) => !_neutralCommands.contains(w.first)).toList();
      // Learn the read-only commands it ran (`gh pr view 12` -> the rule
      // `Bash(gh pr view *)`), so a lookup may run them too, even when the
      // line's output doesn't count below. Only a real program's own
      // subcommands: never a keyword, variable, path or anything after a flag.
      for (final words in commands.where(_isRemoteCommand)) {
        final verb = words.take(5).toList().indexWhere(_readVerb.hasMatch);
        if (verb > 0 &&
            !_shellBuiltins.contains(words.first) &&
            words.take(verb + 1).every(_plainWord.hasMatch) &&
            readCommands.length < maxCalls) {
          readCommands.add('Bash(${words.take(verb + 1).join(' ')} *)');
        }
      }
      // Its output counts only if every command in the line is a remote tool:
      // `gh pr view 1` does, `gh pr list | head` and `flutter test | grep`
      // don't. (`cd`, `export` and the like change nothing the line prints.)
      if (commands.isEmpty || !commands.every(_isRemoteCommand)) return;
      for (final words in commands) {
        final summary = words.join(' ');
        _addCall('\$ ${summary.length > 200 ? '${summary.substring(0, 199)}…' : summary}');
      }
      if (id is String) _pend(id, shell: true);
    }
  }

  void _pend(String id, {required bool shell}) {
    _pendingTools[id] = shell;
    if (_pendingTools.length > 20) _pendingTools.remove(_pendingTools.keys.first);
  }

  void _addCall(String s) {
    toolCalls
      ..remove(s)
      ..add(s);
    if (toolCalls.length > maxCalls) toolCalls.removeAt(0);
  }

  static String _resultText(Object? c) {
    if (c is String) return c;
    if (c is List) return c.whereType<Map>().map((b) => (b['text'] as String?) ?? '').join('\n');
    return '';
  }

  void _addUrls(String text, {required bool shell}) {
    final list = shell ? shellUrls : urls;
    for (final u in LinkDetector.findUrls(text)) {
      list.removeWhere((x) => LinkDetector.sameUrl(x, u));
      list.add(u);
    }
    if (list.length > maxUrls) list.removeRange(0, list.length - maxUrls);
  }

  void _addRefs(String text) {
    for (final r in LinkDetector.findRefs(text)) {
      refs
        ..remove(r)
        ..add(r);
    }
    if (refs.length > maxRefs) refs.removeRange(0, refs.length - maxRefs);
  }

  void _add(ParsedMessage m) {
    _addUrls(m.text, shell: false);
    _addRefs(m.text);
    if (m.fromHuman && firstPrompt == null) {
      final oneLine = m.text.trim().replaceAll(RegExp(r'\s+'), ' ');
      if (oneLine.isNotEmpty) firstPrompt = oneLine.length > 80 ? '${oneLine.substring(0, 79)}…' : oneLine;
    }
    messages.add(m);
    if (messages.length > keep * 2) messages.removeRange(0, messages.length - keep);
  }

  static String _unescape(String s) => s
      .replaceAll('&#39;', "'")
      .replaceAll('&#34;', '"')
      .replaceAll('&quot;', '"')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&');
}

class ParsedMessage {
  final String id;
  final bool fromHuman;
  final String author;
  final DateTime sentAt;
  final String text;

  /// `reply` (a message in the thread) or `notes` (what this computer's
  /// session reported, which the thread shows only as the project assistant's
  /// rewrite).
  final String kind;

  ParsedMessage({
    required this.id,
    required this.fromHuman,
    required this.author,
    required this.sentAt,
    required this.text,
    this.kind = 'reply',
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'from_human': fromHuman,
    'author': author,
    'sent_at': sentAt.toUtc().toIso8601String(),
    'text': text,
    if (kind != 'reply') 'kind': kind,
  };

  static ParsedMessage fromJson(Map<String, dynamic> j) => ParsedMessage(
    id: j['id'] as String,
    fromHuman: j['from_human'] == true,
    author: j['author'] as String,
    sentAt: DateTime.parse(j['sent_at'] as String),
    text: j['text'] as String,
    kind: (j['kind'] as String?) ?? 'reply',
  );
}
