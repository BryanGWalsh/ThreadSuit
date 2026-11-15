import 'dart:async';

import 'package:flutter/material.dart';

import '../services/peer_crypto.dart';
import '../services/peer_service.dart';
import 'format.dart';

/// The top-bar button that opens [ComputersDialog].
class ComputersButton extends StatelessWidget {
  final PeerService peers;
  const ComputersButton({super.key, required this.peers});

  @override
  Widget build(BuildContext context) => IconButton(
    key: const ValueKey('computers'),
    tooltip: 'Your computers',
    icon: const Icon(Icons.devices_outlined),
    onPressed: () => showDialog<void>(
      context: context,
      builder: (_) => ComputersDialog(peers: peers),
    ),
  );
}

/// Pair with your other computers and see the ones you've paired.
class ComputersDialog extends StatefulWidget {
  final PeerService peers;
  const ComputersDialog({super.key, required this.peers});

  @override
  State<ComputersDialog> createState() => _ComputersDialogState();
}

class _ComputersDialogState extends State<ComputersDialog> {
  final _address = TextEditingController();
  Timer? _probe;

  @override
  void initState() {
    super.initState();
    // Ask the network who's there while the dialog is open.
    widget.peers.discover();
    _probe = Timer.periodic(const Duration(seconds: 3), (_) => widget.peers.discover());
  }

  @override
  void dispose() {
    _probe?.cancel();
    _address.dispose();
    // A finished or failed pairing is done with once you close the dialog.
    final o = widget.peers.outgoing;
    if (o != null && o.step != PairingStep.connecting && o.step != PairingStep.comparing) {
      widget.peers.cancelPairing();
    }
    super.dispose();
  }

  /// "192.168.1.20", "desk.tailnet.ts.net", "host:5000" or a full URL.
  static Uri? parseAddress(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    final uri = Uri.tryParse(text.contains('://') ? text : 'http://$text');
    if (uri == null || uri.host.isEmpty) return null;
    return uri.hasPort ? uri : uri.replace(port: PeerService.defaultPort);
  }

  void _pairTyped() {
    final url = parseAddress(_address.text);
    if (url != null) widget.peers.pairWith(url);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final peers = widget.peers;
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline);
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 4),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 0.8, color: theme.colorScheme.outline),
      ),
    );

    return AlertDialog(
      title: const Text('Your computers'),
      content: SizedBox(
        width: 460,
        child: StreamBuilder<OutgoingPairing?>(
          stream: peers.outgoingStream,
          initialData: peers.outgoing,
          builder: (context, o) {
            if (o.data != null) return _OutgoingPanel(pairing: o.data!, peers: peers);
            return SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'See and answer the threads on your other computers. Run Thread Suit on each one, '
                    'then pair them here.',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    peers.listenError ?? 'This computer is "${peers.me.name}".',
                    style: peers.listenError != null
                        ? theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)
                        : muted,
                  ),
                  StreamBuilder<List<PeerStatus>>(
                    stream: peers.statusStream,
                    initialData: peers.status,
                    builder: (context, s) {
                      final paired = s.data ?? const <PeerStatus>[];
                      return StreamBuilder<List<FoundComputer>>(
                        stream: peers.foundStream,
                        initialData: const [],
                        builder: (context, f) {
                          final ids = {for (final p in paired) p.peer.id};
                          final found = [
                            for (final c in f.data ?? const <FoundComputer>[])
                              if (!ids.contains(c.id)) c,
                          ];
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (paired.isNotEmpty) heading('PAIRED'),
                              for (final p in paired)
                                ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  leading: Icon(
                                    p.error == null ? Icons.check_circle_outline : Icons.error_outline,
                                    color: p.error == null ? theme.colorScheme.primary : theme.colorScheme.error,
                                  ),
                                  title: Text(p.peer.name),
                                  subtitle: Text(
                                    p.error ??
                                        (p.seenAt == null
                                            ? 'Connecting…'
                                            : '${p.threads.length} threads · seen ${ago(p.seenAt!)}'),
                                  ),
                                  trailing: TextButton(
                                    onPressed: () => peers.forget(p.peer.id),
                                    child: const Text('Unpair'),
                                  ),
                                ),
                              heading('ON YOUR NETWORK'),
                              if (found.isEmpty) Text('Looking for Thread Suit on other computers…', style: muted),
                              for (final c in found)
                                ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  leading: const Icon(Icons.computer_outlined),
                                  title: Text(c.name),
                                  subtitle: Text(c.url.host),
                                  trailing: FilledButton(
                                    onPressed: () => peers.pairWith(c.url),
                                    child: const Text('Pair'),
                                  ),
                                ),
                            ],
                          );
                        },
                      );
                    },
                  ),
                  heading('OR TYPE ITS ADDRESS'),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const ValueKey('pair-address'),
                          controller: _address,
                          onSubmitted: (_) => _pairTyped(),
                          decoration: const InputDecoration(
                            hintText: '192.168.1.20, or a Tailscale name',
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(onPressed: _pairTyped, child: const Text('Pair')),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Computers on the same network find each other. Away from home, '
                    'a VPN such as Tailscale connects them.',
                    style: muted,
                  ),
                ],
              ),
            );
          },
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
    );
  }
}

/// Pairing this computer started: the code, and where to click Yes.
class _OutgoingPanel extends StatelessWidget {
  final OutgoingPairing pairing;
  final PeerService peers;
  const _OutgoingPanel({required this.pairing, required this.peers});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = pairing.name ?? pairing.url.host;
    final (String message, bool busy, String button) = switch (pairing.step) {
      PairingStep.connecting => ('Connecting to ${pairing.url.host}…', true, 'Cancel'),
      PairingStep.comparing => ('Check that $name shows this same code, then click Yes there.', true, 'Cancel'),
      PairingStep.paired => ('Paired with $name. Its threads will appear in your list.', false, 'Done'),
      PairingStep.rejected => ("$name said the codes don't match, so they weren't paired.", false, 'Back'),
      PairingStep.failed => ("Couldn't pair: ${pairing.error ?? 'unknown error'}", false, 'Back'),
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (pairing.code != null && pairing.step != PairingStep.failed)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: SelectableText(
              PeerCrypto.spaced(pairing.code!),
              key: const ValueKey('pair-code'),
              style: theme.textTheme.displaySmall?.copyWith(letterSpacing: 4, fontWeight: FontWeight.w600),
            ),
          ),
        Text(message, textAlign: TextAlign.center),
        if (busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
        const SizedBox(height: 12),
        TextButton(onPressed: peers.cancelPairing, child: Text(button)),
      ],
    );
  }
}

/// Shows a prompt whenever another computer asks to pair with this one.
class PairingPrompt extends StatefulWidget {
  final PeerService peers;
  final Widget child;
  const PairingPrompt({super.key, required this.peers, required this.child});

  @override
  State<PairingPrompt> createState() => _PairingPromptState();
}

class _PairingPromptState extends State<PairingPrompt> {
  late final StreamSubscription<IncomingPairing?> _sub;
  IncomingPairing? _showing;

  @override
  void initState() {
    super.initState();
    _sub = widget.peers.incomingStream.listen(_changed);
  }

  void _changed(IncomingPairing? p) {
    if (!mounted) return;
    if (p == null) {
      // Cancelled on the other computer, timed out, or answered here.
      if (_showing != null) Navigator.of(context, rootNavigator: true).pop();
      return;
    }
    if (_showing != null) return;
    _showing = p;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => IncomingPairingDialog(pairing: p, onAnswer: widget.peers.answerIncoming),
    ).whenComplete(() => _showing = null);
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class IncomingPairingDialog extends StatelessWidget {
  final IncomingPairing pairing;
  final void Function(bool yes) onAnswer;
  const IncomingPairingDialog({super.key, required this.pairing, required this.onAnswer});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text('Pair with ${pairing.name}?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${pairing.name} wants to see and answer this computer\'s threads. Does it show this same code?'),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: SelectableText(
              PeerCrypto.spaced(pairing.code),
              key: const ValueKey('incoming-code'),
              style: theme.textTheme.displaySmall?.copyWith(letterSpacing: 4, fontWeight: FontWeight.w600),
            ),
          ),
          Text(
            "If you didn't start this, or the codes differ, click No.",
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => onAnswer(false), child: const Text('No')),
        FilledButton(onPressed: () => onAnswer(true), child: const Text('Yes, they match')),
      ],
    );
  }
}

/// For tests.
abstract final class ComputersDialogTestHooks {
  static Uri? parse(String raw) => _ComputersDialogState.parseAddress(raw);
}
