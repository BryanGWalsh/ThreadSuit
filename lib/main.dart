import 'package:complete_dependency_injector/complete_dependency_injector.dart';
import 'package:complete_dependency_injector_flutter/complete_dependency_injector_flutter.dart';
import 'package:flutter/material.dart';

import 'models/models.dart';
import 'platform/claude_platform.dart';
import 'services/data_dir.dart';
import 'services/claude_cli.dart';
import 'services/link_service.dart';
import 'services/local_threads_service.dart';
import 'services/outbox_service.dart';
import 'services/send_service.dart';
import 'services/seen_service.dart';
import 'services/sleep_service.dart';
import 'services/theme_service.dart';
import 'services/title_service.dart';
import 'services/workspace_service.dart';
import 'ui/app_theme.dart';
import 'ui/dashboard_view_model.dart';
import 'ui/thread_column.dart';
import 'ui/thread_list.dart';
import 'ui/tile_grid.dart';

/// [platform] defaults to the running OS (see [ClaudePlatform]); tests can
/// pass a fake one.
Injector buildRootInjector(DataDir dir, [ClaudePlatform? platform]) {
  final os = platform ?? ClaudePlatform.current;
  final injector = Injector([
    Provider.value(DataDir, dir),
    Provider(ClaudeCli),
    Provider(LinkService),
    Provider(LocalThreadsService),
    Provider(SendService),
    Provider(SeenService),
    Provider(SleepService),
    Provider(TitleService),
    Provider(ThemeService),
    Provider(OutboxService),
    Provider(WorkspaceService),
  ]);
  injector.registerFactories([
    InjectableFactory.withoutDependencies<ClaudeCli>(() => ClaudeCli(os)),
    InjectableFactory.withDependencies<LinkService>(
      DependencyDataBuilder.list([DataDir, ClaudeCli, WorkspaceService]),
      (d) {
        final links = LinkService(d.get<DataDir>(), d.get<ClaudeCli>());
        // Look up the links of threads you have open before the rest.
        d.get<WorkspaceService>().openStream.listen((ids) => links.priority = ids.toSet());
        return links;
      },
    ),
    InjectableFactory.withDependencies<LocalThreadsService>(
      DependencyDataBuilder.list([DataDir, LinkService]),
      (d) => LocalThreadsService(d.get<DataDir>(), d.get<LinkService>(), os),
    ),
    InjectableFactory.withDependencies<SendService>(
      DependencyDataBuilder.list([OutboxService, ClaudeCli]),
      (d) => SendService(d.get<OutboxService>(), d.get<ClaudeCli>(), os),
    ),
    InjectableFactory.withDependencies<SeenService>(
      DependencyDataBuilder.list([DataDir]),
      (d) => SeenService(d.get<DataDir>()),
    ),
    InjectableFactory.withDependencies<SleepService>(
      DependencyDataBuilder.list([DataDir]),
      (d) => SleepService(d.get<DataDir>()),
    ),
    InjectableFactory.withDependencies<ThemeService>(
      DependencyDataBuilder.list([DataDir]),
      (d) => ThemeService(d.get<DataDir>()),
    ),
    InjectableFactory.withDependencies<TitleService>(
      DependencyDataBuilder.list([DataDir]),
      (d) => TitleService(d.get<DataDir>()),
    ),
    InjectableFactory.withDependencies<OutboxService>(
      DependencyDataBuilder.list([DataDir]),
      (d) => OutboxService(d.get<DataDir>()),
    ),
    InjectableFactory.withoutDependencies<WorkspaceService>(() => WorkspaceService()),
  ]);
  return injector;
}

void main() {
  runApp(InjectorRootWidget(injector: buildRootInjector(DataDir.resolve()), child: const ThreadSuitApp()));
}

class ThreadSuitApp extends StatelessWidget {
  const ThreadSuitApp({super.key});

  @override
  Widget build(BuildContext context) {
    return DependenciesBuilder<AppViewModel>(
      cleanViewModelInstance: AppViewModel(),
      builder: (context, app) => MaterialApp(
        title: 'Thread Suit',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: app.themeMode,
        home: DependenciesBuilder<DashboardViewModel>(
          cleanViewModelInstance: DashboardViewModel(),
          builder: (context, vm) => dependencyBuilderViewModelSimpleStateHandlingBuildUtilityFn(
            context: context,
            viewModel: vm,
            build: (context, vm) => DashboardScreen(vm: vm),
            loadingWidget: const Scaffold(body: Center(child: CircularProgressIndicator())),
            errorWidget: const Scaffold(body: Center(child: Text('Could not start the dashboard'))),
          ),
        ),
      ),
    );
  }
}

/// The app-wide state above the dashboard: only the theme.
class AppViewModel extends DependencyBuilderViewModelBase {
  late final ThemeService themes;
  ThemeMode themeMode = ThemeMode.system;

  AppViewModel() : super(dependencyDataList: DependencyDataBuilder.list([ThemeService]));

  @override
  void setPropertiesOnDependencyResolution(Dependencies d) {
    themes = d.get<ThemeService>();
    themeMode = themes.mode;
  }

  @override
  Iterable<Stream> getListOfStreamsToObserve() => [themes.modeStream];

  @override
  void updateViewModelPropertiesOnStreamEmission(List s) => themeMode = s[0] as ThemeMode;
}

/// The light/dark switch in the title bar. It shows the theme you're seeing
/// (the system's, until you flip it) and remembers your choice.
class ThemeToggle extends StatelessWidget {
  final ThemeService themes;
  const ThemeToggle({super.key, required this.themes});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final muted = theme.colorScheme.outline;
    return Tooltip(
      message: dark ? 'Switch to light mode' : 'Switch to dark mode',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.light_mode_outlined, size: 18, color: dark ? muted : theme.colorScheme.primary),
          Switch(
            key: const ValueKey('theme-toggle'),
            value: dark,
            onChanged: (v) => themes.set(v ? ThemeMode.dark : ThemeMode.light),
          ),
          Icon(Icons.dark_mode_outlined, size: 18, color: dark ? theme.colorScheme.primary : muted),
        ],
      ),
    );
  }
}

class DashboardScreen extends StatelessWidget {
  final DashboardViewModel vm;
  const DashboardScreen({super.key, required this.vm});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final snap = vm.snapshot;
    final open = vm.openIds.map(vm.thread).whereType<ThreadSummary>().toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Thread Suit'),
        actions: [
          if (vm.snapshotError != null)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: Text(
                  vm.snapshotError!,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                ),
              ),
            ),
          if (vm.openIds.isNotEmpty)
            TextButton.icon(
              onPressed: vm.workspace.closeAll,
              icon: const Icon(Icons.close_fullscreen, size: 18),
              label: Text('Close ${vm.openIds.length} tiles'),
            ),
          if (vm.unreadCount > 0)
            TextButton.icon(
              onPressed: () => vm.seenService.markAllSeen(vm.threads),
              icon: const Icon(Icons.done_all),
              label: Text('Mark ${vm.unreadCount} seen'),
            ),
          const SizedBox(width: 12),
          ThemeToggle(themes: vm.themes),
          const SizedBox(width: 12),
        ],
      ),
      body: snap == null
          ? Center(child: Text(vm.snapshotError ?? 'Loading…', textAlign: TextAlign.center))
          : Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 360,
                  child: ColoredBox(
                    color: theme.colorScheme.surface,
                    child: ThreadList(vm: vm),
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: open.isEmpty
                      ? const Center(
                          child: Text(
                            'Click threads to open them.\nEach one opens as a new tile.',
                            textAlign: TextAlign.center,
                          ),
                        )
                      : TileGrid(
                          children: [
                            for (final t in open) ThreadColumn(key: GlobalObjectKey(t.threadId), vm: vm, thread: t),
                          ],
                        ),
                ),
              ],
            ),
    );
  }
}
