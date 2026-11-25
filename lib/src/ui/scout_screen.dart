import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../bridge/bridge.dart';
import '../theme/tokens.dart';
import 'widgets.dart';

class ScoutModel {
  ScoutModel({
    required this.cli,
    required this.provider,
    required this.id,
    required this.label,
    required this.thinkingLevels,
  });

  final String cli;
  final String provider;
  final String id;
  final String label;
  final List<String> thinkingLevels;

  factory ScoutModel.fromJson(Map<String, dynamic> j) => ScoutModel(
    cli: (j['cli'] as String?) ?? 'omp',
    provider: (j['provider'] as String?) ?? '',
    id: (j['id'] as String?) ?? '',
    label: (j['label'] as String?) ?? (j['id'] as String? ?? ''),
    thinkingLevels: ((j['thinking_levels'] as List?) ?? const [])
        .cast<String>(),
  );
}

class ScoutMessage {
  ScoutMessage({required this.role, required this.text});

  final String role;
  final String text;
}

/// the bridge's own assistant across workspaces; model comes from bridge config, not a CLI flag
class ScoutScreen extends StatefulWidget {
  const ScoutScreen({super.key});

  @override
  State<ScoutScreen> createState() => _ScoutScreenState();
}

class _ScoutScreenState extends State<ScoutScreen> with BridgeAccess {
  final _input = TextEditingController();
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  bool _searching = false;
  int _searchIndex = 0;
  final _matchKeys = <int, GlobalKey>{};
  final List<StagedFile> _staged = [];
  List<Map<String, dynamic>> _workspaces = const [];
  bool _uploading = false;
  bool _multiline = false;
  final _scroll = ScrollController();
  List<ScoutMessage> _messages = const [];
  List<ScoutModel> _models = const [];
  List<Map<String, dynamic>> _sessions = const [];
  Map<String, dynamic> _config = const {};
  String? _sessionId;
  bool _loading = true;
  bool _sending = false;
  bool _running = false;
  String? _error;
  StreamSubscription<Map<String, dynamic>>? _sub;

  @override
  void initState() {
    super.initState();
    _input.addListener(_syncMultiline);
  }

  void _syncMultiline() {
    final multi = _input.text.contains('\n');
    if (multi != _multiline) setState(() => _multiline = multi);
  }

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
            (m) => ScoutMessage(
              role: (m['role'] as String?) ?? 'assistant',
              text: (m['text'] as String?) ?? '',
            ),
          )
          .where((m) => m.text.isNotEmpty)
          .toList();
      if (_search.text.trim().isNotEmpty) _searchIndex = 0;
      _loading = false;
      _error = null;
    });
  }

  Future<void> _load() async {
    try {
      final r = await bridge.call('bridge.assistant.get');
      if (!mounted) return;
      setState(() {
        _models = ((r['models'] as List?) ?? const [])
            .cast<Map<String, dynamic>>()
            .map(ScoutModel.fromJson)
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
    _search.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadWorkspaces() async {
    try {
      final r = await bridge.call('workspace.list');
      if (!mounted) return;
      setState(() {
        _workspaces = ((r['workspaces'] as List?) ?? const [])
            .cast<Map<String, dynamic>>();
      });
    } catch (_) {
      // picker stays empty with a hint if herdr isn't reachable
    }
  }

  Future<void> _pickWorkspaces() async {
    if (_workspaces.isEmpty) await _loadWorkspaces();
    if (!mounted) return;
    final c = context.colors;
    final allowed = ((_config['allowed_workspaces'] as List?) ?? const [])
        .whereType<Map>()
        .map((m) => m['workspace_id'])
        .toSet();
    final selection = <dynamic>{...allowed};
    final picked = await showModalBottomSheet<List<String>>(
      context: context,
      backgroundColor: c.paper,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.card)),
      ),
      builder: (sheet) => SafeArea(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Space.md,
                  Space.md,
                  Space.md,
                  Space.sm,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Scout workspaces',
                        style: nameStyle(context, size: 18),
                      ),
                    ),
                    TextButton(
                      onPressed: () =>
                          Navigator.of(sheet).pop(allowed.toList()),
                      child: Text(
                        'Cancel',
                        style: monoStyle(context, size: 12, color: c.muted),
                      ),
                    ),
                    TextButton(
                      onPressed: () =>
                          Navigator.of(sheet)
                              .pop(selection.map((e) => e as String).toList()),
                      child: Text(
                        'Save',
                        style: monoStyle(context, size: 12, color: c.ink),
                      ),
                    ),
                  ],
                ),
              ),
              Divider(color: c.rule, height: 1),
              Flexible(
                child: _WorkspacePickerSheet(
                  workspaces: _workspaces,
                  selected: allowed,
                  onChange: (next) => selection
                    ..clear()
                    ..addAll(next),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    final ordered = _workspaces
        .where((w) => picked.contains(w['workspace_id']))
        .map(
          (w) => {'connection_id': 'local', 'workspace_id': w['workspace_id']},
        )
        .toList();
    if (ordered.isEmpty) {
      _toast('Keep at least one workspace selected');
      return;
    }
    try {
      await bridge.call('bridge.assistant.configure_chat', {
        'cli': _config['cli'] ?? 'omp',
        'provider': _config['provider'] ?? '',
        'model': _config['model'] ?? '',
        'thinking_level': _config['thinking_level'],
        'allowed_workspaces': ordered,
      });
      await _load();
    } catch (e) {
      if (mounted) _toast('Could not save: $e');
    }
  }

  Future<void> _attach() async {
    final file = await FilePicker.pickFile(type: FileType.any);
    if (file == null) return;
    setState(() => _uploading = true);
    try {
      final bytes = await file.readAsBytes();
      final staged = await bridge.upload(file.name, bytes);
      if (!mounted) return;
      setState(() => _staged.add(staged));
    } catch (e) {
      if (mounted) _toast('Could not attach: $e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _stop() async {
    if (_sessionId == null) return;
    try {
      await bridge.call('bridge.assistant.stop', {'session_id': _sessionId});
    } catch (e) {
      if (mounted) _toast('Could not stop: $e');
    }
  }

  void _toggleSearch() {
    setState(() {
      _searching = !_searching;
      if (!_searching) _search.clear();
    });
    if (_searching) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _searchFocus.requestFocus(),
      );
    }
  }

  List<int> _matchingMessages(String query) {
    final out = <int>[];
    for (var i = 0; i < _messages.length; i++) {
      if (_messages[i].text.toLowerCase().contains(query)) out.add(i);
    }
    return out;
  }

  void _stepMatch(int delta) {
    final query = _search.text.trim().toLowerCase();
    final hits = _matchingMessages(query);
    if (hits.isEmpty) return;
    setState(
      () => _searchIndex = (_searchIndex + delta + hits.length) % hits.length,
    );
    _scrollToMatch(hits[_searchIndex], hits.length);
  }

  void _scrollToMatch(int item, int total, {int attempt = 0}) {
    final key = _matchKeys.putIfAbsent(item, GlobalKey.new);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = key.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.12,
          duration: const Duration(milliseconds: 160),
        );
        return;
      }
      if (attempt >= 2 || !_scroll.hasClients) return;
      final position = _scroll.position;
      final target = total == 1
          ? position.maxScrollExtent
          : position.maxScrollExtent * item / (total - 1);
      _scroll.jumpTo(target.clamp(0.0, position.maxScrollExtent));
      _scrollToMatch(item, total, attempt: attempt + 1);
    });
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message, style: monoStyle(context, size: 12))),
    );
  }

  Future<void> _pickModel() async {
    final c = context.colors;
    // hoisted out of the sheet builder: keyboard open/close rebuilds the
    // sheet, and a fresh notifier would silently reset the active filter
    final query = ValueNotifier('');
    final selected = await showModalBottomSheet<ScoutModel>(
      context: context,
      backgroundColor: c.paper,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.card)),
      ),
      builder: (sheet) {
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
                          '${m.cli} ${m.provider} ${m.label}'
                              .toLowerCase()
                              .contains(q.toLowerCase()),
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
                    ListTile(
                      dense: true,
                      leading: Icon(Icons.link, size: 18, color: c.muted),
                      title: Text(
                        'Custom endpoint',
                        style: monoStyle(context, size: 12.5),
                      ),
                      subtitle: Text(
                        'Any OpenAI-compatible base URL',
                        style: monoStyle(context, size: 10, color: c.muted),
                      ),
                      onTap: () => Navigator.of(sheet).pop(
                        ScoutModel(
                          cli: 'openai',
                          provider: 'custom',
                          id: '',
                          label: 'Custom endpoint',
                          thinkingLevels: const [],
                        ),
                      ),
                    ),
                    Divider(color: c.rule, height: 1),
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
                                    '${m.cli} · ${m.provider}',
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
    query.dispose();
    if (selected == null) return;
    if (selected.cli == 'openai' && selected.id.isEmpty) {
      await _customEndpoint();
      return;
    }
    try {
      await bridge.call('bridge.assistant.configure_chat', {
        'cli': selected.cli,
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

  /// any OpenAI-compatible endpoint; the API key is optional for local servers
  Future<void> _customEndpoint() async {
    final c = context.colors;
    final baseUrl = TextEditingController();
    final apiKey = TextEditingController();
    final model = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        backgroundColor: c.paper,
        title: Text('Custom endpoint', style: nameStyle(context, size: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: baseUrl,
              style: monoStyle(context, size: 12),
              decoration: InputDecoration(
                labelText: 'Base URL',
                hintText: 'https://your-endpoint.example.com/v1',
                hintStyle: monoStyle(context, size: 11, color: c.muted),
              ),
            ),
            const SizedBox(height: Space.sm),
            TextField(
              controller: apiKey,
              style: monoStyle(context, size: 12),
              obscureText: true,
              decoration: InputDecoration(
                labelText: 'API key (optional)',
                hintStyle: monoStyle(context, size: 11, color: c.muted),
              ),
            ),
            const SizedBox(height: Space.sm),
            TextField(
              controller: model,
              style: monoStyle(context, size: 12),
              decoration: InputDecoration(
                labelText: 'Model',
                hintText: 'model-name',
                hintStyle: monoStyle(context, size: 11, color: c.muted),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text('Cancel', style: monoStyle(context, size: 12)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text('Save', style: monoStyle(context, size: 12)),
          ),
        ],
      ),
    );

    if (saved != true || !mounted) return;
    final url = baseUrl.text.trim();
    final id = model.text.trim();
    if (url.isEmpty || id.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Base URL and model are required',
            style: monoStyle(context, size: 12),
          ),
        ),
      );
      return;
    }
    try {
      await bridge.call('bridge.assistant.configure_chat', {
        'cli': 'openai',
        'provider': 'custom',
        'model': id,
        'base_url': url,
        'api_key': apiKey.text.trim(),
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

  Future<void> _confirmDeleteSession(Map<String, dynamic> session) async {
    final c = context.colors;
    final title = (session['title'] as String?) ?? 'Chat';
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        backgroundColor: c.paper,
        title: Text('Delete chat?', style: nameStyle(context, size: 16)),
        content: Text(
          '"$title" and its messages will be removed. This cannot be undone.',
          style: monoStyle(context, size: 12, color: c.ink),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text('Cancel', style: monoStyle(context, size: 12)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(
              'Delete',
              style: monoStyle(context, size: 12, color: c.error),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await bridge.call('bridge.assistant.delete_session', {
        'session_id': session['id'],
      });
      await _load();
    } catch (e) {
      if (mounted) _toast('Could not delete: $e');
    }
  }

  Future<void> _send() async {
    final typed = _input.text.trim();
    final paths = _staged.map((s) => s.path).join(' ');
    final text = [typed, paths].where((s) => s.isNotEmpty).join(' ');
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
      _staged.clear();
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
    final status = connectionSubtitle(context, _error);
    return DrovesScaffold(
      title: 'Scout',
      subtitle: Row(
        children: [
          Flexible(
            child: LedgerLabel(
              status.isNotEmpty
                  ? status
                  : model.isEmpty
                  ? 'no model selected'
                  : '${_config['cli'] ?? 'omp'} $provider/$model',
            ),
          ),
          if (_running || _sending) ...[
            const SizedBox(width: Space.xs),
            LedgerLabel('answering', color: c.error),
          ],
        ],
      ),
      actions: [
        IconButton(
          icon: Icon(
            Icons.search,
            size: 20,
            color: _searching ? c.accent : c.ink,
          ),
          tooltip: _searching ? 'Close search' : 'Search conversation',
          onPressed: _toggleSearch,
        ),
        IconButton(
          icon: const Icon(Icons.folder_open, size: 20),
          color: c.ink,
          tooltip: 'Allowed workspaces',
          onPressed: _pickWorkspaces,
        ),
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
          if (_searching) _searchBar(context),
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
                    child: Tooltip(
                      message: 'Long press to delete chat',
                      child: InkWell(
                        onTap: () async {
                          await bridge.call('bridge.assistant.select_session', {
                            'session_id': s['id'],
                          });
                          await _load();
                        },
                        onLongPress: () => _confirmDeleteSession(s),
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

  Widget _searchBar(BuildContext context) {
    final c = context.colors;
    final query = _search.text.trim().toLowerCase();
    final hits = query.isEmpty ? <int>[] : _matchingMessages(query);
    return Container(
      decoration: BoxDecoration(
        color: c.paper,
        border: Border(bottom: BorderSide(color: c.rule)),
      ),
      padding: const EdgeInsets.fromLTRB(
        Space.sm,
        Space.xs,
        Space.sm,
        Space.xs,
      ),
      child: Row(
        children: [
          Icon(Icons.search, size: 18, color: c.muted),
          const SizedBox(width: Space.xs),
          Expanded(
            child: TextField(
              controller: _search,
              focusNode: _searchFocus,
              onChanged: (_) => setState(() => _searchIndex = 0),
              style: monoStyle(context, size: 12),
              decoration: InputDecoration(
                hintText: 'Search conversation',
                hintStyle: monoStyle(context, size: 12, color: c.muted),
                border: InputBorder.none,
                isDense: true,
              ),
            ),
          ),
          if (query.isNotEmpty)
            Text(
              hits.isEmpty ? '0 matches' : '${_searchIndex + 1}/${hits.length}',
              style: monoStyle(context, size: 10, color: c.muted),
            ),
          if (hits.isNotEmpty)
            IconButton(
              icon: Icon(Icons.keyboard_arrow_up, size: 18, color: c.muted),
              tooltip: 'Previous match',
              onPressed: () => _stepMatch(-1),
            ),
          if (hits.isNotEmpty)
            IconButton(
              icon: Icon(Icons.keyboard_arrow_down, size: 18, color: c.muted),
              tooltip: 'Next match',
              onPressed: () => _stepMatch(1),
            ),
          IconButton(
            icon: Icon(Icons.close, size: 18, color: c.muted),
            tooltip: 'Close search',
            onPressed: _toggleSearch,
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final c = context.colors;
    final live = app.bridge;
    final connected = live != null && live.state == BridgeState.ready;
    final state = ScreenState(
      loading: _loading,
      error: _error,
      connected: connected,
      empty: _messages.isEmpty,
      subject: 'Scout',
      emptyHeadline: 'Ask about your workspaces',
      emptyBody:
          'Scout reads history, diffs, and terminal output through the '
          'bridge. Pick a model first.',
      onRetry: connectionRetry(context, _load),
      rows: 5,
      rowHeight: 72,
      emptyIcon: Icons.auto_awesome_outlined,
      emptyAction: OutlinedButton(
        onPressed: _pickModel,
        child: Text('Pick a model', style: monoStyle(context, size: 12)),
      ),
    );
    if (_loading || !connected || _error != null || _messages.isEmpty) {
      return state;
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
          key: _matchKeys.putIfAbsent(i, GlobalKey.new),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LedgerLabel(
              user ? 'you' : 'scout',
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
    final running = _running || _sending;
    return Container(
      decoration: BoxDecoration(
        color: c.paper,
        border: Border(top: BorderSide(color: c.rule)),
      ),
      padding: const EdgeInsets.fromLTRB(
        Space.sm,
        Space.sm,
        Space.sm,
        Space.sm,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_staged.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.xs),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: Space.xs,
                    runSpacing: Space.xs,
                    children: [
                      for (var i = 0; i < _staged.length; i++)
                        StagedChip(
                          name: _staged[i].name,
                          onRemove: () => setState(() => _staged.removeAt(i)),
                        ),
                    ],
                  ),
                ),
              ),
            Row(
              crossAxisAlignment: _multiline
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.center,
              children: [
                IconButton(
                  onPressed: _uploading ? null : _attach,
                  color: c.muted,
                  tooltip: 'Attach a file',
                  icon: _uploading
                      ? SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.6,
                            color: c.muted,
                          ),
                        )
                      : const Icon(Icons.attach_file, size: 20),
                ),
                Expanded(
                  child: TextField(
                    controller: _input,
                    textAlignVertical: TextAlignVertical.center,
                    minLines: 1,
                    maxLines: 5,
                    style: monoStyle(context, size: 13),
                    decoration: InputDecoration(
                      hintText: 'Ask Scout',
                      hintStyle: monoStyle(
                        context,
                        size: 12,
                        color: c.muted.withValues(alpha: 0.8),
                      ),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: Space.sm,
                        vertical: 12,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: Space.xs),
                SizedBox(
                  height: 44,
                  width: 44,
                  child: IconButton.filled(
                    onPressed: running ? _stop : _send,
                    style: IconButton.styleFrom(
                      backgroundColor: running ? c.error : c.ink,
                      foregroundColor: c.paper,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(Radii.row),
                      ),
                    ),
                    tooltip: running ? 'Stop (Esc)' : 'Send',
                    icon: Icon(
                      running ? Icons.stop : Icons.arrow_upward,
                      size: 18,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkspacePickerSheet extends StatefulWidget {
  const _WorkspacePickerSheet({
    required this.workspaces,
    required this.selected,
    required this.onChange,
  });

  final List<Map<String, dynamic>> workspaces;
  final Set<dynamic> selected;
  final ValueChanged<Set<dynamic>> onChange;

  @override
  State<_WorkspacePickerSheet> createState() => _WorkspacePickerSheetState();
}

class _WorkspacePickerSheetState extends State<_WorkspacePickerSheet> {
  late final Set<dynamic> _selected = {...widget.selected};

  void _toggle(dynamic id) {
    setState(() {
      if (!_selected.add(id)) _selected.remove(id);
      widget.onChange(_selected);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (widget.workspaces.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Text(
          'No workspaces available from herdr.',
          style: monoStyle(context, size: 12, color: c.muted),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: Space.md),
      itemCount: widget.workspaces.length,
      separatorBuilder: (_, _) => Divider(color: c.rule, height: 1),
      itemBuilder: (_, i) {
        final w = widget.workspaces[i];
        final id = w['workspace_id'];
        final label = (w['label'] as String?) ?? (id as String? ?? '?');
        final root = (w['cwd'] as String?) ?? '';
        return CheckboxListTile(
          dense: true,
          value: _selected.contains(id),
          activeColor: c.ink,
          onChanged: (_) => _toggle(id),
          title: Text(label, style: monoStyle(context, size: 12.5)),
          subtitle: Text(
            root,
            style: monoStyle(context, size: 10, color: c.muted),
          ),
        );
      },
    );
  }
}
