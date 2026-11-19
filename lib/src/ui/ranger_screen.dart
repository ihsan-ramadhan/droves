import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../theme/tokens.dart';
import 'widgets.dart';

class RangerModel {
  RangerModel({
    required this.provider,
    required this.id,
    required this.label,
    required this.thinkingLevels,
  });

  final String provider;
  final String id;
  final String label;
  final List<String> thinkingLevels;

  factory RangerModel.fromJson(Map<String, dynamic> j) => RangerModel(
    provider: (j['provider'] as String?) ?? '',
    id: (j['id'] as String?) ?? '',
    label: (j['label'] as String?) ?? (j['id'] as String? ?? ''),
    thinkingLevels: ((j['thinking_levels'] as List?) ?? const [])
        .cast<String>(),
  );
}

class RangerMessage {
  RangerMessage({required this.role, required this.text});

  final String role;
  final String text;
}

/// the bridge's own assistant across workspaces; model comes from bridge config, not a CLI flag
class RangerScreen extends StatefulWidget {
  const RangerScreen({super.key});

  @override
  State<RangerScreen> createState() => _RangerScreenState();
}

class _RangerScreenState extends State<RangerScreen> with BridgeAccess {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  List<RangerMessage> _messages = const [];
  List<RangerModel> _models = const [];
  List<Map<String, dynamic>> _sessions = const [];
  Map<String, dynamic> _config = const {};
  String? _sessionId;
  bool _loading = true;
  bool _sending = false;
  bool _running = false;
  String? _error;
  StreamSubscription<Map<String, dynamic>>? _sub;

  @override
  void onBridgeReady() {
    _sub ??= bridge.events.listen((event) {
      if (event['event'] != 'assistant') return;
      final snapshot = (event['data'] as Map?)?.cast<String, dynamic>();
      if (snapshot != null) _apply(snapshot);
    });
    _load();
  }

  void _apply(Map<String, dynamic> snapshot) {
    if (!mounted) return;
    setState(() {
      _config =
          (snapshot['config'] as Map?)?.cast<String, dynamic>() ?? _config;
      _sessionId = snapshot['session_id'] as String? ?? _sessionId;
      _running = snapshot['running'] == true;
      _sessions = ((snapshot['sessions'] as List?) ?? const [])
          .cast<Map<String, dynamic>>();
      final raw = ((snapshot['messages'] as List?) ?? const [])
          .cast<Map<String, dynamic>>();
      _messages = raw
          .map(
            (m) => RangerMessage(
              role: (m['role'] as String?) ?? 'assistant',
              text: (m['text'] as String?) ?? '',
            ),
          )
          .where((m) => m.text.isNotEmpty)
          .toList();
      _loading = false;
    });
  }

  Future<void> _load() async {
    try {
      final r = await bridge.call('bridge.assistant.get');
      if (!mounted) return;
      setState(() {
        _models = ((r['models'] as List?) ?? const [])
            .cast<Map<String, dynamic>>()
            .map(RangerModel.fromJson)
            .toList();
      });
      _apply(r);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _pickModel() async {
    final c = context.colors;
    final selected = await showModalBottomSheet<RangerModel>(
      context: context,
      backgroundColor: c.paper,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.card)),
      ),
      builder: (sheet) {
        final query = ValueNotifier('');
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(sheet).height * 0.7,
            child: ValueListenableBuilder<String>(
              valueListenable: query,
              builder: (context, q, _) {
                final filtered = _models
                    .where(
                      (m) =>
                          q.isEmpty ||
                          '${m.provider} ${m.label}'.toLowerCase().contains(
                            q.toLowerCase(),
                          ),
                    )
                    .toList();
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(Space.md),
                      child: TextField(
                        autofocus: true,
                        onChanged: (v) => query.value = v,
                        style: monoStyle(context, size: 13),
                        decoration: InputDecoration(
                          hintText: 'Filter models',
                          hintStyle: monoStyle(
                            context,
                            size: 12,
                            color: c.muted,
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(Radii.row),
                            borderSide: BorderSide(color: c.rule),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(Radii.row),
                            borderSide: BorderSide(color: c.ink),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: filtered.isEmpty
                          ? StateMessage(
                              headline: 'No models',
                              body: _models.isEmpty
                                  ? 'Add a model provider on the bridge first.'
                                  : 'Nothing matches that filter.',
                              icon: Icons.tune,
                            )
                          : ListView.separated(
                              itemCount: filtered.length,
                              separatorBuilder: (_, _) =>
                                  Divider(color: c.rule, height: 1),
                              itemBuilder: (_, i) {
                                final m = filtered[i];
                                return ListTile(
                                  title: Text(
                                    m.label,
                                    style: monoStyle(context, size: 12.5),
                                  ),
                                  subtitle: Text(
                                    m.provider,
                                    style: monoStyle(
                                      context,
                                      size: 10,
                                      color: c.muted,
                                    ),
                                  ),
                                  onTap: () => Navigator.of(sheet).pop(m),
                                );
                              },
                            ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
    if (selected == null) return;
    try {
      await bridge.call('bridge.assistant.configure_chat', {
        'provider': selected.provider,
        'model': selected.id,
        'thinking_level': selected.thinkingLevels.isEmpty
            ? null
            : selected.thinkingLevels.first,
      });
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString(), style: monoStyle(context, size: 12)),
        ),
      );
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    final provider = (_config['provider'] as String?) ?? '';
    final model = (_config['model'] as String?) ?? '';
    if (provider.isEmpty || model.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Pick a model first',
            style: monoStyle(context, size: 12),
          ),
        ),
      );
      return;
    }
    setState(() => _sending = true);
    try {
      // the bridge rejects sends outside the authorized scope; take it from the saved config
      final scope = ((_config['allowed_workspaces'] as List?) ?? const [])
          .whereType<Map>()
          .map(
            (ref) => {
              'connection_id': ref['connection_id'],
              'workspace_id': ref['workspace_id'],
            },
          )
          .toList();
      await bridge.call('bridge.assistant.send', {
        'text': text,
        'scope': scope,
        'request_id': DateTime.now().microsecondsSinceEpoch.toString(),
        if (_sessionId != null) 'session_id': _sessionId,
      });
      _input.clear();
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString(), style: monoStyle(context, size: 12)),
        ),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final model = (_config['model'] as String?) ?? '';
    final provider = (_config['provider'] as String?) ?? '';
    return DrovesScaffold(
      title: 'Ranger',
      subtitle: LedgerLabel(
        model.isEmpty ? 'no model selected' : '$provider / $model',
      ),
      leading: IconButton(
        icon: const Icon(Icons.arrow_back, size: 20),
        color: c.ink,
        tooltip: 'Back',
        onPressed: () => Navigator.of(context).maybePop(),
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.tune, size: 20),
          color: c.ink,
          tooltip: 'Pick model',
          onPressed: _pickModel,
        ),
        IconButton(
          icon: const Icon(Icons.add, size: 20),
          color: c.ink,
          tooltip: 'New chat',
          onPressed: () async {
            await bridge.call('bridge.assistant.new_session', {});
            await _load();
          },
        ),
      ],
      child: Column(
        children: [
          if (_sessions.length > 1)
            SizedBox(
              height: 40,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: Space.md),
                itemCount: _sessions.length,
                separatorBuilder: (_, _) => const SizedBox(width: Space.sm),
                itemBuilder: (_, i) {
                  final s = _sessions[i];
                  final active = s['id'] == _sessionId;
                  return Center(
                    child: InkWell(
                      onTap: () async {
                        await bridge.call('bridge.assistant.select_session', {
                          'session_id': s['id'],
                        });
                        await _load();
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: Space.md,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: active ? c.ink : Colors.transparent,
                          border: Border.all(color: active ? c.ink : c.rule),
                          borderRadius: BorderRadius.circular(Radii.row),
                        ),
                        child: Text(
                          (s['title'] as String?) ?? 'Chat',
                          style: monoStyle(
                            context,
                            size: 10.5,
                            color: active ? c.paper : c.ink,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          Expanded(child: _buildBody(context)),
          _composer(context),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final c = context.colors;
    if (_loading) {
      return const SkeletonRows(rows: 5, rowHeight: 72);
    }
    if (_error != null) {
      return StateMessage(
        headline: 'Ranger is not answering',
        body: _error!,
        icon: Icons.error_outline,
        action: OutlinedButton(
          onPressed: _load,
          child: Text('Try again', style: monoStyle(context, size: 12)),
        ),
      );
    }
    if (_messages.isEmpty) {
      return StateMessage(
        headline: 'Ask about your workspaces',
        body:
            'Ranger reads history, diffs, and terminal output through the '
            'bridge. Pick a model first.',
        icon: Icons.auto_awesome_outlined,
        action: OutlinedButton(
          onPressed: _pickModel,
          child: Text('Pick a model', style: monoStyle(context, size: 12)),
        ),
      );
    }
    return ListView.separated(
      controller: _scroll,
      padding: const EdgeInsets.all(Space.md),
      itemCount: _messages.length,
      separatorBuilder: (_, _) => const SizedBox(height: Space.md),
      itemBuilder: (_, i) {
        final m = _messages[i];
        final user = m.role == 'user';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LedgerLabel(
              user ? 'you' : 'ranger',
              color: user ? c.muted : c.accent,
            ),
            const SizedBox(height: Space.xs),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(Space.md),
              decoration: BoxDecoration(
                color: user ? null : c.surface,
                border: Border.all(color: c.rule),
                borderRadius: BorderRadius.circular(Radii.card),
              ),
              child: SelectableText(
                m.text,
                style: monoStyle(context, size: 12.5),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _composer(BuildContext context) {
    final c = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: c.paper,
        border: Border(top: BorderSide(color: c.rule)),
      ),
      padding: const EdgeInsets.fromLTRB(Space.sm, Space.sm, Space.sm, 0),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (_running)
              Padding(
                padding: const EdgeInsets.only(right: Space.sm, bottom: 12),
                child: LedgerLabel('answering', color: c.accent),
              ),
            Expanded(
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 5,
                style: monoStyle(context, size: 13),
                decoration: InputDecoration(
                  hintText: 'Ask Ranger',
                  hintStyle: monoStyle(
                    context,
                    size: 12,
                    color: c.muted.withValues(alpha: 0.8),
                  ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: Space.sm,
                    vertical: 12,
                  ),
                ),
              ),
            ),
            SizedBox(
              width: 44,
              height: 44,
              child: IconButton.filled(
                onPressed: _sending ? null : _send,
                style: IconButton.styleFrom(
                  backgroundColor: c.ink,
                  foregroundColor: c.paper,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(Radii.row),
                  ),
                ),
                tooltip: 'Send',
                icon: const Icon(Icons.arrow_upward, size: 18),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
