/// Threads read from this computer's Claude session files, and messages queued in
/// `outbox/` for delivery. See docs/FILE_FORMAT.md.
library;

import '../services/link_detector.dart';

export '../services/link_detector.dart' show LinkKind, ResolvedLink;

/// Claude's own status for the thread. Kept from the snapshot but not shown:
/// you mark threads Awake or Asleep yourself instead.
enum ThreadState {
  blocked,
  reviewReady,
  working,
  done,
  failed,
  stopped,
  unknown;

  static ThreadState parse(String? raw) => switch (raw) {
    'blocked' => blocked,
    'review_ready' => reviewReady,
    'working' => working,
    'done' => done,
    'failed' => failed,
    'stopped' => stopped,
    _ => unknown,
  };
}

class ThreadMessage {
  final String id;
  final String author;
  final bool fromHuman;
  final DateTime sentAt;
  final String text;

  /// Status cards and session notices, shown as a single muted line.
  final bool isEvent;

  const ThreadMessage({
    this.isEvent = false,
    required this.id,
    required this.author,
    required this.fromHuman,
    required this.sentAt,
    required this.text,
  });

  factory ThreadMessage.fromJson(Map<String, dynamic> j) => ThreadMessage(
    id: j['id'] as String,
    author: (j['author'] as String?) ?? (j['from_human'] == true ? 'You' : 'Claude'),
    fromHuman: j['from_human'] == true,
    sentAt: DateTime.parse(j['sent_at'] as String),
    text: (j['text'] as String?) ?? '',
    isEvent: j['kind'] == 'event',
  );
}

/// A PR, issue or other item a thread is about (see [ResolvedLink]).
typedef ThreadLink = ResolvedLink;

class ThreadSummary {
  final String threadId;
  final String? sessionId;
  final String title;
  final ThreadState state;
  final DateTime lastActivityAt;
  final bool resolved;
  final List<ThreadMessage> messages;

  /// The activity time the stored messages were fetched at.
  final DateTime? messagesAsOf;

  final List<ThreadLink> links;

  /// The claude.ai project the thread belongs to; null when it has none.
  final String? project;

  /// The title from Claude's data when you've renamed the thread in Thread
  /// Suit ([title] is then your name for it); null otherwise.
  final String? originalTitle;

  const ThreadSummary({
    this.originalTitle,
    this.project,
    this.links = const [],
    this.messagesAsOf,
    required this.threadId,
    required this.sessionId,
    required this.title,
    required this.state,
    required this.lastActivityAt,
    required this.resolved,
    required this.messages,
  });

  /// This thread shown as [newTitle], remembering the title it had.
  ThreadSummary renamed(String newTitle) => ThreadSummary(
    originalTitle: originalTitle ?? title,
    project: project,
    links: links,
    messagesAsOf: messagesAsOf,
    threadId: threadId,
    sessionId: sessionId,
    title: newTitle,
    state: state,
    lastActivityAt: lastActivityAt,
    resolved: resolved,
    messages: messages,
  );

  factory ThreadSummary.fromJson(Map<String, dynamic> j) => ThreadSummary(
    threadId: j['thread_id'] as String,
    sessionId: j['session_id'] as String?,
    title: (j['title'] as String?) ?? 'Untitled thread',
    state: ThreadState.parse(j['state'] as String?),
    lastActivityAt: DateTime.parse(j['last_activity_at'] as String),
    resolved: j['resolved'] == true,
    project: j['project'] as String?,
    links: ((j['links'] as List?) ?? const []).map(ThreadLink.fromJson).whereType<ThreadLink>().toList(),
    messagesAsOf: j['messages_as_of'] == null ? null : DateTime.parse(j['messages_as_of'] as String),
    messages:
        ((j['messages'] as List?) ?? const []).map((m) => ThreadMessage.fromJson(m as Map<String, dynamic>)).toList()
          ..sort((a, b) => a.sentAt.compareTo(b.sentAt)),
  );

  /// When the newest real message (not a status notice) arrived. If the
  /// stored messages are older than the thread's activity, assume the newer
  /// activity may be a message.
  DateTime? get lastMessageAt {
    if (messagesAsOf == null || lastActivityAt.isAfter(messagesAsOf!)) return lastActivityAt;
    return messages.where((m) => !m.isEvent).lastOrNull?.sentAt;
  }
}

class Snapshot {
  final DateTime generatedAt;
  final String projectName;
  final List<ThreadSummary> threads;

  const Snapshot({required this.generatedAt, required this.projectName, required this.threads});

  factory Snapshot.fromJson(Map<String, dynamic> j) => Snapshot(
    generatedAt: DateTime.parse(j['generated_at'] as String),
    projectName: ((j['project'] as Map?)?['name'] as String?) ?? 'Project',
    threads: ((j['threads'] as List?) ?? const [])
        .map((t) => ThreadSummary.fromJson(t as Map<String, dynamic>))
        .toList(),
  );
}

class OutboxMessage {
  final String id;
  final String threadId;

  /// The desktop app's id for the thread's session (`local_…`), used to find
  /// the running session to deliver to.
  final String sessionId;
  final String text;
  final DateTime queuedAt;

  const OutboxMessage({
    required this.id,
    required this.threadId,
    required this.sessionId,
    required this.text,
    required this.queuedAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'thread_id': threadId,
    'session_id': sessionId,
    'text': text,
    'queued_at': queuedAt.toUtc().toIso8601String(),
  };

  factory OutboxMessage.fromJson(Map<String, dynamic> j) => OutboxMessage(
    id: j['id'] as String,
    threadId: j['thread_id'] as String,
    sessionId: (j['session_id'] as String?) ?? '',
    text: j['text'] as String,
    queuedAt: DateTime.parse(j['queued_at'] as String),
  );
}
