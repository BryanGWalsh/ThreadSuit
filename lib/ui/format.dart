import 'package:flutter/material.dart';

String ago(DateTime t, {DateTime? now}) {
  final d = (now ?? DateTime.now()).difference(t);
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}

final _mdLink = RegExp(r'\[([^\]]+)\]\((https?://[^)\s]+)\)');

/// Renders **bold**, shows [text](url) links as their text, and drops `code`
/// backticks; enough for status replies.
TextSpan lightMarkdown(String text, TextStyle? base) {
  final spans = <TextSpan>[];
  final parts = text.replaceAllMapped(_mdLink, (m) => m.group(1)!).replaceAll('`', '').split('**');
  for (var i = 0; i < parts.length; i++) {
    spans.add(
      TextSpan(
        text: parts[i],
        style: i.isOdd ? const TextStyle(fontWeight: FontWeight.w700) : null,
      ),
    );
  }
  return TextSpan(style: base, children: spans);
}

String plainPreview(String text) =>
    text.replaceAllMapped(_mdLink, (m) => m.group(1)!).replaceAll('**', '').replaceAll('`', '').replaceAll('\n', ' ');
