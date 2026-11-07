import 'package:flutter/material.dart';

import '../models/models.dart';
import '../platform/claude_platform.dart';

void openUrl(String url) => ClaudePlatform.current.openUrl(url);

/// One line per link, e.g. "GitHub #1530: title" or "Jira ABC-12", each
/// opening in the browser. Shows nothing when the thread has no links.
class ThreadLinks extends StatelessWidget {
  final List<ThreadLink> links;
  final int max;
  const ThreadLinks({super.key, required this.links, this.max = 4});

  @override
  Widget build(BuildContext context) {
    if (links.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final shown = links.take(max).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final l in shown)
          Tooltip(
            message: l.state == null ? l.text : '${l.text} (${_stateLabel(l.state!)})',
            waitDuration: const Duration(milliseconds: 500),
            child: InkWell(
              onTap: () => openUrl(l.url),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Row(
                  children: [
                    Icon(_icon(l.kind), size: 14, color: theme.colorScheme.primary),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: l.title == null ? l.label : '${l.label}: ',
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                            TextSpan(text: l.title ?? ''),
                            if (l.state != null)
                              TextSpan(
                                text: '  ${_stateLabel(l.state!)}',
                                style: TextStyle(color: theme.colorScheme.outline),
                              ),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.primary,
                          decoration: TextDecoration.underline,
                          decorationColor: theme.colorScheme.primary.withValues(alpha: 0.4),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (links.length > max) Text('+${links.length - max} more', style: theme.textTheme.bodySmall),
      ],
    );
  }

  static IconData _icon(LinkKind k) => switch (k) {
    LinkKind.pullRequest => Icons.merge_type,
    LinkKind.issue => Icons.task_alt,
    LinkKind.other => Icons.link,
  };

  static String _stateLabel(String s) => switch (s) {
    'OPEN' => 'open',
    'MERGED' => 'merged',
    'CLOSED' => 'closed',
    _ => s.toLowerCase(),
  };
}
