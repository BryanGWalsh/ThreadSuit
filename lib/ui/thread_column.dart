import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';
import '../platform/claude_platform.dart';
import 'dashboard_view_model.dart';
import 'editable_title.dart';
import 'app_theme.dart';
import 'format.dart';
import 'thread_links.dart';

class ThreadColumn extends StatefulWidget {
  final DashboardViewModel vm;
  final ThreadSummary thread;
  const ThreadColumn({super.key, required this.vm, required this.thread});

  @override
  State<ThreadColumn> createState() => _ThreadColumnState();
}

class _ThreadColumnState extends State<ThreadColumn> with SingleTickerProviderStateMixin {
  final _controller = TextEditingController();
  late final AnimationController _flash = AnimationController(vsync: this, duration: const Duration(milliseconds: 500));
  late final StreamSubscription<String> _highlightSub;

  @override
  void initState() {
    super.initState();
    if (widget.vm.workspace.takeJustOpened(widget.thread.threadId)) _flash.forward(from: 0);
    _highlightSub = widget.vm.workspace.highlightStream.listen((id) {
      if (id == widget.thread.threadId) _flash.forward(from: 0);
    });
  }

  @override
  void dispose() {
    _highlightSub.cancel();
    _flash.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _send() {
    if (_controller.text.trim().isEmpty) return;
    widget.vm.send(widget.thread, _controller.text);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final vm = widget.vm;
    final t = widget.thread;
    final theme = Theme.of(context);
    final asleep = vm.isAsleep(t);
    final unread = !asleep && vm.isUnread(t);
    final pending = vm.pendingFor(t.threadId);

    final restBorder = unread
        ? BorderSide(color: AppTheme.unread(theme.brightness), width: 2)
        : BorderSide(color: theme.colorScheme.outlineVariant);
    // Any click inside the tile counts as reading it.
    return AnimatedBuilder(
      animation: _flash,
      builder: (context, _) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) {
          if (unread) vm.seenService.markSeen(t);
        },
        child: Card(
          margin: const EdgeInsets.all(6),
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: _flashed(restBorder, theme)),
          // During a flash, a white wash fades in and out over the whole tile.
          child: Container(
            foregroundDecoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.6 * _flashLevel)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  color: theme.colorScheme.surfaceContainerHigh,
                  padding: const EdgeInsets.fromLTRB(12, 4, 4, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Title bar: the title on the left, the thread's buttons top right.
                      Row(
                        children: [
                          Expanded(
                            child: EditableTitle(
                              title: t.title,
                              originalTitle: t.originalTitle,
                              style: theme.textTheme.titleSmall,
                              onRename: (name) => widget.vm.rename(t, name),
                            ),
                          ),
                          // Open tiles are awake, so this always offers sleep;
                          // sleeping also closes the tile.
                          IconButton(
                            tooltip: 'Sleep until a new message',
                            visualDensity: VisualDensity.compact,
                            onPressed: () => vm.sleep(t),
                            icon: const Icon(Icons.bedtime_outlined, size: 18),
                          ),
                          IconButton(
                            tooltip: 'Close',
                            visualDensity: VisualDensity.compact,
                            onPressed: () => vm.workspace.close(t.threadId),
                            icon: const Icon(Icons.close, size: 18),
                          ),
                        ],
                      ),
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              t.project != null ? 'Project: ${t.project}' : 'Claude Code session',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall,
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Text('Active ${ago(t.lastActivityAt)}', style: theme.textTheme.bodySmall),
                                if (asleep) ...[
                                  const SizedBox(width: 8),
                                  Icon(Icons.bedtime_outlined, size: 14, color: theme.colorScheme.outline),
                                  Text(
                                    ' Asleep',
                                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                                  ),
                                ],
                              ],
                            ),
                            if (t.links.isNotEmpty) ...[const SizedBox(height: 6), ThreadLinks(links: t.links)],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: t.messages.isEmpty && pending.isEmpty
                      ? const Center(child: Text('No recent messages in the snapshot'))
                      : ListView(
                          reverse: true,
                          padding: const EdgeInsets.all(12),
                          children: [
                            for (final m in pending.reversed)
                              _QueuedBubble(
                                message: m,
                                status: vm.sendStatus[m.id],
                                onCancel: () => vm.outbox.cancel(m),
                              ),
                            for (final m in t.messages.reversed) _MessageBubble(message: m),
                          ],
                        ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: CallbackShortcuts(
                    bindings: {
                      SingleActivator(
                        LogicalKeyboardKey.enter,
                        meta: ClaudePlatform.current.usesCommandKey,
                        control: !ClaudePlatform.current.usesCommandKey,
                      ): _send,
                    },
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _controller,
                            minLines: 1,
                            maxLines: 6,
                            decoration: InputDecoration(
                              hintText: 'Message this thread (${ClaudePlatform.current.sendShortcutLabel} to send)',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        IconButton.filled(
                          tooltip: 'Send',
                          onPressed: _send,
                          // The theme's muted icon colour would win otherwise.
                          icon: Icon(Icons.send, size: 18, color: theme.colorScheme.onPrimary),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 0 at rest, rising to 1 halfway through a flash and back to 0.
  double get _flashLevel => math.sin(math.pi * _flash.value);

  /// The border during a flash: it swells to the accent color and back.
  BorderSide _flashed(BorderSide rest, ThemeData theme) {
    final v = _flashLevel;
    if (v <= 0) return rest;
    return BorderSide(
      color: Color.lerp(rest.color, theme.colorScheme.primary, v)!,
      width: lerpDouble(rest.width, 4, v)!,
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final ThreadMessage message;
  const _MessageBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mine = message.fromHuman;
    if (message.isEvent) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(
          '${message.text} · ${ago(message.sentAt)}',
          textAlign: TextAlign.center,
          style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline),
        ),
      );
    }
    if (message.isNotes) return NotesBubble(message: message);
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(10),
        constraints: const BoxConstraints(maxWidth: 560),
        decoration: BoxDecoration(
          color: mine ? theme.colorScheme.primaryContainer : theme.colorScheme.surfaceContainer,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${mine ? message.author : 'Claude'} · ${ago(message.sentAt)}', style: theme.textTheme.labelSmall),
            const SizedBox(height: 4),
            SelectableText.rich(lightMarkdown(message.text, theme.textTheme.bodyMedium)),
          ],
        ),
      ),
    );
  }
}

/// What this computer's session reported for a Remote Control project
/// thread. The thread itself shows the project assistant's rewrite, which
/// isn't stored locally, so this is labelled as notes, muted, and collapsed
/// to a few lines until clicked.
class NotesBubble extends StatefulWidget {
  final ThreadMessage message;
  const NotesBubble({super.key, required this.message});

  @override
  State<NotesBubble> createState() => NotesBubbleState();
}

class NotesBubbleState extends State<NotesBubble> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.outline;
    final body = lightMarkdown(widget.message.text, theme.textTheme.bodyMedium?.copyWith(color: muted));
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(10),
        constraints: const BoxConstraints(maxWidth: 560),
        decoration: BoxDecoration(
          border: Border.all(color: theme.colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Tooltip(
              message: 'What Claude on this computer reported. The thread shows the project assistant\'s summary.',
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.notes, size: 14, color: muted),
                  const SizedBox(width: 4),
                  Text(
                    'Working notes from this computer · ${ago(widget.message.sentAt)}',
                    style: theme.textTheme.labelSmall,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            if (_open)
              SelectableText.rich(body)
            else
              Text.rich(body, key: const ValueKey('notes-collapsed'), maxLines: 3, overflow: TextOverflow.ellipsis),
            TextButton(
              key: const ValueKey('notes-toggle'),
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () => setState(() => _open = !_open),
              child: Text(_open ? 'Show less' : 'Show more'),
            ),
          ],
        ),
      ),
    );
  }
}

class _QueuedBubble extends StatelessWidget {
  final OutboxMessage message;
  final String? status;
  final VoidCallback onCancel;
  const _QueuedBubble({required this.message, required this.status, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.fromLTRB(10, 6, 4, 10),
        constraints: const BoxConstraints(maxWidth: 560),
        decoration: BoxDecoration(
          border: Border.all(color: theme.colorScheme.outline),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(child: Text(status ?? 'Queued', style: theme.textTheme.labelSmall)),
                IconButton(
                  tooltip: 'Cancel',
                  visualDensity: VisualDensity.compact,
                  iconSize: 16,
                  onPressed: onCancel,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            Text(message.text),
          ],
        ),
      ),
    );
  }
}
