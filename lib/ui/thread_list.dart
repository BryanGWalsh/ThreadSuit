import 'package:flutter/material.dart';

import '../models/models.dart';
import 'app_theme.dart';
import 'dashboard_view_model.dart';
import 'editable_title.dart';
import 'format.dart';

class ThreadList extends StatefulWidget {
  final DashboardViewModel vm;
  const ThreadList({super.key, required this.vm});

  @override
  State<ThreadList> createState() => _ThreadListState();
}

class _ThreadListState extends State<ThreadList> {
  bool _showAsleep = false;

  @override
  Widget build(BuildContext context) {
    final vm = widget.vm;
    final theme = Theme.of(context);
    // Two sections, Awake then Asleep, each newest activity first.
    // Resolved threads stay listed so you can wake them.
    final visible = vm.threads.toList()..sort((a, b) => b.lastActivityAt.compareTo(a.lastActivityAt));
    final awake = visible.where((t) => !vm.isAsleep(t)).toList();
    final asleep = visible.where(vm.isAsleep).toList();

    Widget header(IconData icon, String label, int count, {bool? expanded, VoidCallback? onTap}) => InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Row(
          children: [
            Icon(icon, size: 14, color: theme.colorScheme.outline),
            const SizedBox(width: 6),
            Text(
              '$label  $count',
              style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 0.8, color: theme.colorScheme.outline),
            ),
            const Spacer(),
            if (expanded != null)
              Icon(expanded ? Icons.expand_less : Icons.expand_more, size: 16, color: theme.colorScheme.outline),
          ],
        ),
      ),
    );

    final rows = <Widget>[
      if (awake.isNotEmpty) header(Icons.wb_sunny_outlined, 'AWAKE', awake.length),
      for (final t in awake) _ThreadRow(vm: vm, thread: t),
      if (asleep.isNotEmpty)
        header(
          Icons.bedtime_outlined,
          'ASLEEP',
          asleep.length,
          expanded: _showAsleep,
          onTap: () => setState(() => _showAsleep = !_showAsleep),
        ),
      if (_showAsleep)
        for (final t in asleep)
          Opacity(
            opacity: 0.6,
            child: _ThreadRow(vm: vm, thread: t),
          ),
    ];

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              const Spacer(),
              Text('${awake.length} awake · ${asleep.length} asleep', style: theme.textTheme.bodySmall),
            ],
          ),
        ),
        Expanded(
          child: rows.isEmpty
              ? const Center(child: Text('No threads to show'))
              : ListView(padding: const EdgeInsets.only(bottom: 16), children: rows),
        ),
      ],
    );
  }
}

class _ThreadRow extends StatelessWidget {
  final DashboardViewModel vm;
  final ThreadSummary thread;
  const _ThreadRow({required this.vm, required this.thread});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final asleep = vm.isAsleep(thread);
    final unread = !asleep && vm.isUnread(thread);
    final isOpen = vm.openIds.contains(thread.threadId);
    final last = thread.messages.where((m) => !m.isEvent).lastOrNull;
    final pendingCount = vm.pendingFor(thread.threadId).length;

    return Material(
      color: isOpen ? theme.colorScheme.primaryContainer.withValues(alpha: 0.5) : Colors.transparent,
      child: InkWell(
        onTap: () => vm.open(thread),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 6, right: 8),
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: unread ? AppTheme.unread(theme.brightness) : Colors.transparent,
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: EditableTitle(
                            title: thread.title,
                            originalTitle: thread.originalTitle,
                            style: TextStyle(
                              fontWeight: unread ? FontWeight.w700 : FontWeight.w500,
                              color: unread ? AppTheme.unread(theme.brightness) : null,
                            ),
                            onRename: (name) => vm.rename(thread, name),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(ago(thread.lastActivityAt), style: theme.textTheme.bodySmall),
                      ],
                    ),

                    Padding(
                      padding: const EdgeInsets.only(top: 3, bottom: 1),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              thread.project != null ? 'Project: ${thread.project}' : 'Claude Code session',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (last != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          '${last.fromHuman ? 'You' : last.isNotes ? 'Notes' : 'Claude'}: ${plainPreview(last.text)}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    if (thread.links.any((l) => l.kind != LinkKind.other))
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          thread.links.where((l) => l.kind != LinkKind.other).map((l) => l.shortKey).join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary),
                        ),
                      ),
                    if (pendingCount > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          '$pendingCount queued to send',
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.tertiary),
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                tooltip: asleep ? 'Wake' : 'Sleep until a new message',
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                onPressed: () => vm.toggleSleep(thread),
                icon: Icon(asleep ? Icons.wb_sunny_outlined : Icons.bedtime_outlined),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
