// Renders the dashboard from a real snapshot to a PNG, for checking the UI
// without screen-recording access. Not part of the normal test run:
//   SNAPSHOT_DIR=~/.thread-suit OUT=/path/shot.png flutter test tool_test/screenshot_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:complete_dependency_injector_flutter/complete_dependency_injector_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thread_suit/main.dart';
import 'package:thread_suit/services/data_dir.dart';
import 'package:thread_suit/services/local_threads_service.dart';
import 'package:thread_suit/services/workspace_service.dart';

Future<void> loadFont(String family, String path) async {
  final bytes = File(path).readAsBytesSync();
  await (FontLoader(family)..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
}

void main() {
  testWidgets('screenshot', (tester) async {
    final src = Platform.environment['SNAPSHOT_DIR']!;
    final out = Platform.environment['OUT']!;
    final tmp = Directory.systemTemp.createTempSync('shot');
    for (final name in ['projects.json', 'links.json', 'cache.json']) {
      final f = File('$src/$name');
      if (f.existsSync()) f.copySync('${tmp.path}/$name');
    }

    // Tests render with a placeholder font; load a real one. FONT picks the
    // file, otherwise the first that exists of the usual macOS, Linux and
    // Windows system fonts.
    final font = [
      Platform.environment['FONT'],
      '/System/Library/Fonts/SFNS.ttf',
      '/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf',
      '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
      r'C:\Windows\Fonts\segoeui.ttf',
    ].whereType<String>().firstWhere((f) => File(f).existsSync(),
        orElse: () => throw StateError('No font found; set FONT to a .ttf file'));
    final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? '';
    await tester.runAsync(() async {
      // The app's text theme asks for the system font under these names.
      for (final family in ['Roboto', '.AppleSystemUIFont', 'CupertinoSystemText', 'CupertinoSystemDisplay']) {
        await loadFont(family, font);
      }
      await loadFont('MaterialIcons', '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
    });
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    if (Platform.environment['THEME'] == 'dark') {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    }

    final key = GlobalKey();
    final injector = buildRootInjector(DataDir.at(tmp.path));
    await tester.pumpWidget(RepaintBoundary(
        key: key, child: InjectorRootWidget(injector: injector, child: const ThreadSuitApp())));
    // Let the first scan of the local transcripts finish.
    for (var i = 0; i < 60 && find.textContaining('AWAKE').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 500)));
      await tester.pump();
    }
    final svc = await tester.runAsync(() => injector.getService<LocalThreadsService>());
    final threads = (await tester.runAsync(() => svc!.stateStream.first))!.snapshot!.threads;
    // Open the four most recently active threads; they tile 2x2.
    final ws = await tester.runAsync(() => injector.getService<WorkspaceService>());
    for (final t in (threads.toList()..sort((a, b) => b.lastActivityAt.compareTo(a.lastActivityAt))).take(4)) {
      ws!.open(t.threadId);
    }
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }

    // Let the flashes of the newly opened tiles finish.
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // FLASH=1: capture the first tile mid-flash, as if clicked again in the list.
    if (Platform.environment['FLASH'] == '1') {
      final first = (threads.toList()..sort((a, b) => b.lastActivityAt.compareTo(a.lastActivityAt))).first;
      ws!.open(first.threadId);
      await tester.pump();
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    await tester.runAsync(() async {
      final boundary = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File(out).writeAsBytesSync(png!.buffer.asUint8List());
      await injector.dispose();
    });
    tmp.deleteSync(recursive: true);
  });
}
