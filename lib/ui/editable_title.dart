import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A thread title you can rename in place. The pencil next to it is faint
/// until you hover the title (and always clickable); clicking it swaps the
/// title for a text field. Enter or clicking away saves, Esc cancels, and
/// saving an empty name restores the thread's own title. When the thread is
/// renamed, hovering the title shows its original one.
class EditableTitle extends StatefulWidget {
  final String title;
  final String? originalTitle;
  final TextStyle? style;
  final ValueChanged<String> onRename;

  const EditableTitle({super.key, required this.title, required this.onRename, this.originalTitle, this.style});

  @override
  State<EditableTitle> createState() => _EditableTitleState();
}

class _EditableTitleState extends State<EditableTitle> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _editing = false;
  bool _hover = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && _editing) _finish(save: true);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _start() {
    _controller
      ..text = widget.title
      ..selection = TextSelection(baseOffset: 0, extentOffset: widget.title.length);
    setState(() => _editing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  void _finish({required bool save}) {
    if (!_editing) return;
    setState(() => _editing = false);
    if (!save) return;
    final text = _controller.text.trim();
    // An unchanged title isn't a rename.
    if (text == widget.title) return;
    // Empty clears the rename; typing the original title back clears it too.
    widget.onRename(text == widget.originalTitle ? '' : text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_editing) {
      return Focus(
        onKeyEvent: (_, e) {
          if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
            _finish(save: false);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: TextField(
          key: const ValueKey('rename-field'),
          controller: _controller,
          focusNode: _focus,
          style: widget.style,
          maxLines: 1,
          decoration: const InputDecoration(
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            hintText: 'Empty to use the thread\'s own title',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => _finish(save: true),
          onTapOutside: (_) => _focus.unfocus(),
        ),
      );
    }
    final text = Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: widget.style);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Row(
        children: [
          Flexible(
            child: widget.originalTitle == null
                ? text
                : Tooltip(message: 'Renamed from: ${widget.originalTitle}', child: text),
          ),
          Opacity(
            opacity: _hover ? 1 : 0.35,
            child: IconButton(
              key: const ValueKey('rename-button'),
              tooltip: 'Rename (only in Thread Suit)',
              icon: const Icon(Icons.edit_outlined),
              iconSize: 14,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              color: theme.colorScheme.outline,
              onPressed: _start,
            ),
          ),
        ],
      ),
    );
  }
}
