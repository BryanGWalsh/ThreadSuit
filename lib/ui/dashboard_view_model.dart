import 'package:complete_dependency_injector/complete_dependency_injector.dart';
import 'package:complete_dependency_injector_flutter/complete_dependency_injector_flutter.dart';

import '../models/models.dart';
import '../services/outbox_service.dart';
import '../services/seen_service.dart';
import '../services/sleep_service.dart';
import '../services/theme_service.dart';
import '../services/title_service.dart';
import '../services/local_threads_service.dart';
import '../services/send_service.dart';
import '../services/workspace_service.dart';

class DashboardViewModel extends DependencyBuilderViewModelBase {
  late final LocalThreadsService snapshots;
  late final SendService sender;
  late final SeenService seenService;
  late final SleepService sleepService;
  late final TitleService titleService;
  late final ThemeService themes;
  late final OutboxService outbox;
  late final WorkspaceService workspace;

  Snapshot? snapshot;
  String? snapshotError;
  Map<String, DateTime> seen = const {};
  Map<String, DateTime> slept = const {};
  List<String> openIds = const [];
  List<OutboxMessage> pending = const [];
  Map<String, String> sendStatus = const {};
  List<ThreadSummary> _threads = const [];

  DashboardViewModel()
    : super(
        dependencyDataList: DependencyDataBuilder.list([
          LocalThreadsService,
          SeenService,
          SleepService,
          OutboxService,
          WorkspaceService,
          SendService,
          TitleService,
          ThemeService,
        ]),
      );

  @override
  void setPropertiesOnDependencyResolution(Dependencies d) {
    snapshots = d.get<LocalThreadsService>();
    sender = d.get<SendService>();
    seenService = d.get<SeenService>();
    sleepService = d.get<SleepService>();
    outbox = d.get<OutboxService>();
    workspace = d.get<WorkspaceService>();
    titleService = d.get<TitleService>();
    themes = d.get<ThemeService>();
  }

  @override
  Iterable<Stream> getListOfStreamsToObserve() => [
    snapshots.stateStream,
    seenService.seenStream,
    workspace.openStream,
    outbox.pendingStream,
    sleepService.sleepStream,
    sender.statusStream,
    titleService.titlesStream,
  ];

  @override
  void updateViewModelPropertiesOnStreamEmission(List s) {
    final state = s[0] as SnapshotState;
    snapshot = state.snapshot;
    snapshotError = state.error;
    seen = s[1] as Map<String, DateTime>;
    openIds = s[2] as List<String>;
    pending = s[3] as List<OutboxMessage>;
    slept = s[4] as Map<String, DateTime>;
    sendStatus = s[5] as Map<String, String>;
    // Your names for threads win over every title Claude's data gives.
    _threads = TitleService.apply(snapshot?.threads ?? const [], s[6] as Map<String, String>);
  }

  List<ThreadSummary> get threads => _threads;

  ThreadSummary? thread(String id) {
    for (final t in threads) {
      if (t.threadId == id) return t;
    }
    return null;
  }

  bool isUnread(ThreadSummary t) => SeenService.isUnread(t, seen);

  bool isAsleep(ThreadSummary t) => SleepService.isAsleep(t, slept);

  /// Asleep threads don't count: they're out of the way until a message wakes them.
  int get unreadCount => threads.where((t) => !isAsleep(t) && isUnread(t)).length;

  void toggleSleep(ThreadSummary t) => isAsleep(t) ? sleepService.wake(t) : sleep(t);

  /// Puts [t] to sleep and closes its tile: it's out of the way until a new
  /// message wakes it.
  void sleep(ThreadSummary t) {
    sleepService.sleep(t);
    workspace.close(t.threadId);
  }

  List<OutboxMessage> pendingFor(String threadId) => pending.where((m) => m.threadId == threadId).toList();

  /// Opens [t] as a tile. Opening an asleep thread wakes it, so every open
  /// tile is awake.
  void open(ThreadSummary t) {
    workspace.open(t.threadId);
    seenService.markSeen(t);
    sleepService.wake(t);
  }

  /// Shows [t] as [title] in Thread Suit only; an empty title restores its own.
  void rename(ThreadSummary t, String title) => titleService.rename(t.threadId, title);

  void send(ThreadSummary t, String text) {
    outbox.queue(t.threadId, t.sessionId ?? '', text);
    seenService.markSeen(t);
    sleepService.wake(t);
  }
}
