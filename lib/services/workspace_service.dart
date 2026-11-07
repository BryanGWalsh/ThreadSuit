import 'package:complete_dependency_injector/complete_dependency_injector.dart';
import 'package:rxdart/rxdart.dart';

/// The open thread tiles, in the order they were opened.
class WorkspaceService implements InjectableWithDisposeInterface {
  static const maxTiles = 9;
  final _open = BehaviorSubject<List<String>>.seeded(const []);
  final _highlight = PublishSubject<String>();

  Stream<List<String>> get openStream => _open.stream;

  /// Emits a thread id when you open a thread that's already showing, so its
  /// tile can flash to show you where it is.
  Stream<String> get highlightStream => _highlight.stream;

  final _justOpened = <String>{};

  /// True once for a tile that was just added, so it can flash when it first
  /// appears. (Its widget doesn't exist yet when [open] runs.)
  bool takeJustOpened(String threadId) => _justOpened.remove(threadId);

  /// Adds a tile for the thread. Past [maxTiles], the oldest tile closes.
  void open(String threadId) {
    final cur = [..._open.value];
    if (cur.contains(threadId)) {
      _highlight.add(threadId);
      return;
    }
    _justOpened.add(threadId);
    cur.add(threadId);
    if (cur.length > maxTiles) cur.removeAt(0);
    _open.add(cur);
  }

  void close(String threadId) => _open.add([..._open.value]..remove(threadId));

  void closeAll() => _open.add(const []);

  @override
  Future<void> dispose() async {
    await _highlight.close();
    await _open.close();
  }
}
