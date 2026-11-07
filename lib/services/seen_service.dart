import '../models/models.dart';
import 'data_dir.dart';
import 'timestamp_store.dart';

/// Remembers when each thread was last looked at in this app.
/// A thread is unread when it has activity newer than that time.
class SeenService extends TimestampStore {
  SeenService(DataDir dir) : super(dir.seen);

  Stream<Map<String, DateTime>> get seenStream => stream;

  static bool isUnread(ThreadSummary t, Map<String, DateTime> seen) {
    final at = seen[t.threadId];
    return at == null || t.lastActivityAt.isAfter(at);
  }

  void markSeen(ThreadSummary t) {
    final current = value[t.threadId];
    if (current != null && !t.lastActivityAt.isAfter(current)) return;
    set({...value, t.threadId: t.lastActivityAt});
  }

  void markUnread(ThreadSummary t) => set({...value}..remove(t.threadId));

  void markAllSeen(Iterable<ThreadSummary> threads) =>
      set({...value, for (final t in threads) t.threadId: t.lastActivityAt});
}
