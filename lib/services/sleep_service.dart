import '../models/models.dart';
import 'data_dir.dart';
import 'timestamp_store.dart';

/// Threads you've put to sleep. A thread stays asleep until a message newer
/// than the last one you could see when you slept it arrives. Status notices
/// (session offline, checklist updates) don't wake it.
class SleepService extends TimestampStore {
  SleepService(DataDir dir) : super(dir.sleep);

  Stream<Map<String, DateTime>> get sleepStream => stream;

  static bool isAsleep(ThreadSummary t, Map<String, DateTime> slept) {
    final at = slept[t.threadId];
    if (at == null) return false;
    final last = t.lastMessageAt;
    return last == null || !last.isAfter(at);
  }

  // Keyed to the newest message on screen, not the clock, so a message that
  // arrived before you slept it but hadn't synced yet still wakes it.
  void sleep(ThreadSummary t) => set({...value, t.threadId: t.lastMessageAt ?? t.lastActivityAt});

  void wake(ThreadSummary t) {
    if (!value.containsKey(t.threadId)) return;
    set({...value}..remove(t.threadId));
  }
}
