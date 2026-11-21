import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/gestures.dart';
import 'package:url_launcher/url_launcher.dart';

import '../platform_web_stub.dart'
    if (dart.library.js_interop) '../platform_web.dart'
    as platform;
import '../bridge/bridge.dart';
import '../model/app_state.dart';
import '../theme/tokens.dart';
import 'mermaid_block.dart';
import 'terminal_screen.dart';
import 'widgets.dart';

class AgentMessage {
  AgentMessage({
    required this.id,
    required this.role,
    required this.text,
    this.kind = 'message',
    this.toolName,
    this.isError = false,
    this.textBytes,
    this.sentAt,
  });

  final String id;
  final String role;

  /// `message`, `tool_call`, `tool_result` or `error`.
  final String kind;
  final String text;
  final String? toolName;
  final bool isError;

  /// bridge withheld the payload; [bridge.historyEntry] loads it on demand
  final int? textBytes;
  final String? sentAt;

  bool get isUser => role == 'user';
  bool get isTool => kind == 'tool_call' || kind == 'tool_result';
}

/// bridge projects each CLI transcript into a uniform `messages` array;
/// replies type into the pane via `pane.send_text`
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.pane, required this.label});

  final PaneInfo pane;
  final String label;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with BridgeAccess {
  final _scroll = ScrollController();
  final _input = TextEditingController();
  final _inputFocus = FocusNode();
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  List<AgentMessage> _messages = const [];
  bool _loading = true;
  String? _error;
  bool _sending = false;
  bool _uploading = false;
  bool _searching = false;
  bool _pinned = true;
  int _searchIndex = 0;
  final Map<String, GlobalKey> _matchKeys = {};
  static const _page = 40;
  int _visible = _page;

  /// frozen right-edge count; new turns stay out of the window while set
  int? _frozenEnd;
  bool _prepending = false;
  String get _cacheKey =>
      'droves.transcript.${widget.pane.paneId}.${widget.pane.terminalId}';
  String get _draftKey =>
      'droves.draft.${widget.pane.paneId}.${widget.pane.terminalId}';
  List<String> _reasoning = const [];
  bool _reasoningOpen = false;
  bool _reasoningBusy = false;

  /// staged on the bridge host, kept out of the text field while composing
  final List<StagedFile> _staged = [];
  Timer? _poll;

  /// live pane status; widget.pane is only the snapshot from route creation
  bool _agentActive = false;
  String _agentStatus = 'unknown';

  @override
  void initState() {
    super.initState();
    _agentStatus = widget.pane.agentStatus;
    final warm = _TranscriptCache.memory(_cacheKey);
    if (warm != null && warm.isNotEmpty) {
      _messages = warm;
      _loading = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_frozenEnd == null) _jumpToBottom();
      });
    } else {
      _TranscriptCache.load(_cacheKey).then((cached) {
        if (!mounted || cached.isEmpty || _messages.isNotEmpty) return;
        setState(() {
          _messages = cached;
          _loading = false;
        });
        if (_frozenEnd == null) _jumpToBottom();
      });
    }
    _input.addListener(_persistDraft);
    _DraftStore.load(_draftKey).then((draft) {
      if (!mounted || draft == null) return;
      if (_input.text.isNotEmpty || _staged.isNotEmpty) return;
      setState(() {
        _input.text = draft.text;
        _staged.addAll(draft.staged);
      });
      _input.selection = TextSelection.collapsed(offset: _input.text.length);
    });
    _scroll.addListener(_onScroll);
  }

  @override
  void onBridgeReady() {
    _poll?.cancel();
    unawaited(_load());
    unawaited(_refreshAgentStatus());
    // no transcript subscription on the bridge; poll cheaply
    _poll = Timer.periodic(const Duration(seconds: 3), (_) {
      unawaited(_load(silent: true));
      unawaited(_refreshAgentStatus());
    });
  }

  /// rebuild only on pinned-threshold crossings, not every scroll pixel
  void _onScroll() {
    final pinned = _atBottom;
    if (pinned != _pinned || (pinned && _frozenEnd != null)) {
      final thawing = pinned && _frozenEnd != null;
      setState(() {
        _pinned = pinned;
        // reaching the tail by hand rejoins the live stream
        if (pinned) _frozenEnd = null;
      });
      if (thawing) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_scroll.hasClients) return;
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        });
      }
    }
    if (!pinned) {
      // freeze the right edge; new turns land outside the rendered slice
      if (_frozenEnd == null) setState(() => _frozenEnd = _messages.length);
      if (_prepending || _search.text.trim().isNotEmpty) return;
      if (_scroll.position.pixels > 240) return;
      final window = _windowBlocks();
      if (_visible >= window.length) return;
      // anchor scroll before setState so the prepend doesn't shift the view
      final beforeMax = _scroll.position.maxScrollExtent;
      final beforePixels = _scroll.position.pixels;
      _prepending = true;
      setState(() => _visible += _page);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _prepending = false;
        if (!_scroll.hasClients) return;
        final delta = _scroll.position.maxScrollExtent - beforeMax;
        if (delta > 0) {
          _scroll.jumpTo(
            (beforePixels + delta).clamp(0.0, _scroll.position.maxScrollExtent),
          );
        }
      });
    }
  }

  @override
  void dispose() {
    _persistDraft();
    _poll?.cancel();
    _scroll.dispose();
    _input.dispose();
    _inputFocus.dispose();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      // history_version: 2 is what returns tool calls and results
      final r = await bridge.call('agent_history.get', {
        'pane_id': widget.pane.paneId,
        'terminal_id': widget.pane.terminalId,
        'history_version': 2,
      });
      final raw = (r['entries'] as List?) ?? const [];
      final next = raw
          .cast<Map<String, dynamic>>()
          .map((m) {
            return AgentMessage(
              id: (m['id'] as String?) ?? '',
              role: (m['role'] as String?) ?? 'assistant',
              kind: (m['kind'] as String?) ?? 'message',
              text: (m['text'] as String?) ?? '',
              toolName: m['tool_name'] as String?,
              isError: m['is_error'] == true,
              textBytes: (m['text_bytes'] as num?)?.toInt(),
              sentAt: m['sent_at'] as String?,
            );
          })
          // reasoning belongs to the toggle; older bridges still ship it here
          .where((m) => m.kind != 'reasoning')
          .where((m) => m.kind != 'message' || m.text.isNotEmpty)
          .toList();
      if (!mounted) return;
      final grew = next.length != _messages.length;
      // follow new turns only when pinned to the live tail before this snapshot
      final follow = _pinned && _frozenEnd == null && _atBottom;
      setState(() {
        if (!follow) _frozenEnd ??= _messages.length;
        _messages = next;
        _loading = false;
        _error = null;
        // live snapshot can shrink the match set; clamp the counter
        final query = _search.text.trim().toLowerCase();
        if (query.isNotEmpty) {
          final n = _matchingBlocks(query).length;
          if (n > 0 && _searchIndex >= n) _searchIndex = n - 1;
        }
      });
      if (grew && follow) _jumpToBottom();
      if (grew || !silent) _TranscriptCache.save(_cacheKey, next);
      if (grew && _reasoningOpen) unawaited(_loadReasoning());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (!silent) _error = e.toString();
      });
    }
  }

  Future<void> _refreshAgentStatus() async {
    try {
      final panes = await bridge.panes(widget.pane.workspaceId);
      final live = panes.firstWhere(
        (p) => p.paneId == widget.pane.paneId,
        orElse: () => widget.pane,
      );
      final active = live.agentStatus == 'working';
      if (!mounted ||
          (active == _agentActive && live.agentStatus == _agentStatus)) {
        return;
      }
      setState(() {
        _agentActive = active;
        _agentStatus = live.agentStatus;
      });
    } catch (_) {
      // best-effort poll; keep the last known status when the bridge is down
    }
  }

  bool get _atBottom {
    if (!_scroll.hasClients) return true;
    final p = _scroll.position;
    return p.maxScrollExtent - p.pixels < 80;
  }

  void _jumpToBottom() {
    if (_pinned != true || _frozenEnd != null) {
      setState(() {
        _pinned = true;
        _frozenEnd = null;
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
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

  /// the staged path joins the message at send time; that's how CLIs see files
  Future<void> _attach() async {
    final file = await FilePicker.pickFile(type: FileType.any);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    setState(() => _uploading = true);
    try {
      final staged = await bridge.upload(file.name, bytes);
      setState(() => _staged.add(staged));
      _persistDraft();
    } catch (e) {
      if (mounted) _toast('Could not attach: $e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _removeStaged(int index) {
    setState(() => _staged.removeAt(index));
    _persistDraft();
  }

  /// only staged paths need storing; files already live on the bridge host
  void _persistDraft() {
    unawaited(_DraftStore.save(_draftKey, _input.text, _staged));
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message, style: monoStyle(context, size: 12))),
    );
  }

  Future<void> _interrupt() async {
    try {
      await bridge.sendText(widget.pane.paneId, '\x1b');
    } catch (e) {
      _toast('Could not interrupt: $e');
    }
  }

  Future<void> _send() async {
    final typed = _input.text.trim();
    // the CLI only sees files the prompt names, so paths ride at the end
    final paths = _staged.map((s) => s.path).join(' ');
    final text = [typed, paths].where((s) => s.isNotEmpty).join(' ');
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await bridge.sendPrompt(widget.pane.paneId, text);
      _input.clear();
      _staged.clear();
      await _DraftStore.clear(_draftKey);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      unawaited(_refreshAgentStatus());
      await _load(silent: true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString(), style: monoStyle(context, size: 12)),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return DrovesScaffold(
      title: widget.label,
      subtitle: Row(
        children: [
          StatusWord(_agentStatus),
          const SizedBox(width: Space.sm),
          Text(
            widget.pane.agent ?? 'agent',
            style: monoStyle(context, size: 10, color: c.muted),
          ),
        ],
      ),
      leading: IconButton(
        icon: const Icon(Icons.arrow_back, size: 20),
        color: c.ink,
        tooltip: 'Back',
        onPressed: () => Navigator.of(context).maybePop(),
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.terminal, size: 20),
          color: c.ink,
          tooltip: 'Terminal',
          // replace the route so Back stays pointed at the workspace
          onPressed: () => Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (_) => TerminalScreen(
                pane: widget.pane,
                workspaceLabel: widget.label,
              ),
            ),
          ),
        ),
        if (widget.pane.agent != null && widget.pane.agent!.isNotEmpty)
          IconButton(
            icon: const Icon(Icons.psychology_outlined, size: 20),
            color: _reasoningOpen ? c.accent : c.ink,
            tooltip: _reasoningOpen ? 'Hide reasoning' : 'Show reasoning',
            onPressed: _toggleReasoning,
          ),
        IconButton(
          icon: const Icon(Icons.search, size: 20),
          color: _searching ? c.accent : c.ink,
          tooltip: _searching ? 'Close search' : 'Search transcript',
          onPressed: _toggleSearch,
        ),
        IconButton(
          icon: const Icon(Icons.refresh, size: 20),
          color: c.ink,
          tooltip: 'Reload transcript',
          onPressed: () => _load(),
        ),
      ],
      child: Column(
        children: [
          if (_searching) _searchBar(context),
          Expanded(child: _buildBody(context)),
          _Composer(
            controller: _input,
            focusNode: _inputFocus,
            sending: _sending,
            active: _agentActive,
            onSend: _send,
            onInterrupt: _interrupt,
            onAttach: _attach,
            attaching: _uploading,
            staged: _staged,
            onRemove: _removeStaged,
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const SkeletonRows(rows: 4, rowHeight: 92);
    }
    if (_error != null) {
      return StateMessage(
        headline: 'Transcript unavailable',
        body: _error!,
        icon: Icons.error_outline,
        action: OutlinedButton(
          onPressed: () => _load(),
          child: Text('Try again', style: monoStyle(context, size: 12)),
        ),
      );
    }
    if (_messages.isEmpty) {
      return StateMessage(
        headline: 'No messages yet',
        body: 'Type below to send the agent its first line.',
        icon: Icons.chat_bubble_outline,
      );
    }
    final query = _search.text.trim().toLowerCase();
    final all = query.isEmpty ? _windowBlocks() : _matchingBlocks(query);
    final blocks = query.isEmpty && all.length > _visible
        ? all.sublist(all.length - _visible)
        : all;
    if (query.isNotEmpty && blocks.isEmpty) {
      return Center(
        child: Text(
          'No matches for “${_search.text.trim()}”',
          style: monoStyle(context, size: 12, color: context.colors.muted),
        ),
      );
    }
    return Stack(
      children: [
        RefreshIndicator(
          color: context.colors.ink,
          onRefresh: () => _load(silent: true),
          child: ListView.separated(
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(
              Space.md,
              Space.md,
              Space.md,
              Space.lg,
            ),
            itemCount:
                blocks.length + (query.isEmpty && _reasoningOpen ? 1 : 0),
            separatorBuilder: (_, _) => const SizedBox(height: Space.md),
            itemBuilder: (_, i) {
              if (i == blocks.length) {
                return _ReasoningGroup(
                  steps: _reasoning,
                  busy: _reasoningBusy,
                  onClose: _toggleReasoning,
                );
              }
              final block = blocks[i];
              final id = block is List<AgentMessage>
                  ? block.first.id
                  : (block as AgentMessage).id;
              final child = block is List<AgentMessage>
                  ? _ToolRun(key: ValueKey(id), messages: block, query: query)
                  : _MessageBlock(message: block as AgentMessage, query: query);
              if (query.isEmpty) return child;
              final selected = i == _searchIndex;
              return KeyedSubtree(
                key: _matchKeys.putIfAbsent(id, GlobalKey.new),
                child: selected
                    ? Container(
                        padding: const EdgeInsets.only(left: 6),
                        decoration: BoxDecoration(
                          border: Border(
                            left: BorderSide(
                              color: context.colors.accent,
                              width: 2,
                            ),
                          ),
                        ),
                        child: child,
                      )
                    : child,
              );
            },
          ),
        ),
        if (query.isEmpty && (!_pinned || _frozenEnd != null))
          Positioned(
            right: Space.md,
            bottom: Space.md,
            child: _LatestButton(onTap: _jumpToBottom),
          ),
      ],
    );
  }

  Future<void> _toggleReasoning() async {
    final open = !_reasoningOpen;
    setState(() => _reasoningOpen = open);
    if (open) await _loadReasoning();
  }

  Future<void> _loadReasoning() async {
    setState(() => _reasoningBusy = true);
    try {
      final steps = await bridge.sessionReasoning(
        widget.pane.paneId,
        widget.pane.workspaceId,
        widget.pane.tabId,
      );
      if (mounted) setState(() => _reasoning = steps);
    } catch (_) {
      // reasoning is additive; a failed read leaves the transcript intact
    } finally {
      if (mounted) setState(() => _reasoningBusy = false);
    }
  }

  void _stepMatch(String query, int delta) {
    final n = _matchingBlocks(query).length;
    if (n == 0) return;
    setState(() => _searchIndex = (_searchIndex + delta + n) % n);
    _scrollToMatch();
  }

  /// deep matches aren't built yet; jump approximately, then align next frame
  void _scrollToMatch({int attempt = 0}) {
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return;
    final blocks = _matchingBlocks(query);
    if (blocks.isEmpty) return;
    final index = _searchIndex.clamp(0, blocks.length - 1);
    final id = blocks[index] is List<AgentMessage>
        ? (blocks[index] as List<AgentMessage>).first.id
        : (blocks[index] as AgentMessage).id;
    final key = _matchKeys.putIfAbsent(id, GlobalKey.new);
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
      final p = _scroll.position;
      final target = blocks.length == 1
          ? p.maxScrollExtent
          : p.maxScrollExtent * index / (blocks.length - 1);
      _scroll.jumpTo(target.clamp(0.0, p.maxScrollExtent));
      _scrollToMatch(attempt: attempt + 1);
    });
  }

  List<Object> _matchingBlocks(String query) {
    return _blocks().where((block) {
      if (block is List<AgentMessage>) {
        return block.any((m) => _matches(m, query));
      }
      return _matches(block as AgentMessage, query);
    }).toList();
  }

  bool _matches(AgentMessage m, String query) {
    return m.text.toLowerCase().contains(query) ||
        (m.toolName?.toLowerCase().contains(query) ?? false);
  }

  Widget _searchBar(BuildContext context) {
    final c = context.colors;
    final query = _search.text.trim().toLowerCase();
    final hits = _messages.where((m) => _matches(m, query)).length;
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
              onChanged: (_) {
                setState(() {
                  _searchIndex = 0;
                  _matchKeys.clear();
                });
                _scrollToMatch();
              },
              style: monoStyle(context, size: 12),
              decoration: InputDecoration(
                hintText: 'Search transcript',
                hintStyle: monoStyle(context, size: 12, color: c.muted),
                border: InputBorder.none,
                isDense: true,
              ),
            ),
          ),
          if (query.isNotEmpty)
            Text(
              hits == 0
                  ? '0 matches'
                  : '${_searchIndex + 1} / ${_matchingBlocks(query).length}',
              style: monoStyle(context, size: 10, color: c.muted),
            ),
          if (query.isNotEmpty)
            IconButton(
              icon: Icon(Icons.keyboard_arrow_up, size: 18, color: c.muted),
              tooltip: 'Previous match',
              onPressed: () => _stepMatch(query, -1),
            ),
          if (query.isNotEmpty)
            IconButton(
              icon: Icon(Icons.keyboard_arrow_down, size: 18, color: c.muted),
              tooltip: 'Next match',
              onPressed: () => _stepMatch(query, 1),
            ),
          IconButton(
            icon: Icon(Icons.close, size: 18, color: c.muted),
            tooltip: 'Clear search',
            onPressed: () {
              _search.clear();
              setState(() {
                _searchIndex = 0;
                _matchKeys.clear();
              });
            },
          ),
        ],
      ),
    );
  }

  /// consecutive tool entries collapse into one run; prose stays ungrouped
  List<Object> _blocks([Iterable<AgentMessage>? messages]) {
    final blocks = <Object>[];
    List<AgentMessage>? run;
    for (final m in messages ?? _messages) {
      final tool = m.isTool || (m.kind == 'error' && !m.isUser);
      if (tool) {
        (run ??= []).add(m);
      } else {
        if (run != null) {
          blocks.add(run);
          run = null;
        }
        blocks.add(m);
      }
    }
    if (run != null) blocks.add(run);
    return blocks;
  }

  int get _windowEnd =>
      (_frozenEnd ?? _messages.length).clamp(0, _messages.length);

  /// older pages grow from the left; new turns wait for a return to latest
  List<Object> _windowBlocks() => _blocks(_messages.take(_windowEnd));
}

/// collapsed tool run keeps the transcript's shape on a phone
class _ToolRun extends StatefulWidget {
  const _ToolRun({super.key, required this.messages, this.query = ''});

  final List<AgentMessage> messages;
  final String query;

  @override
  State<_ToolRun> createState() => _ToolRunState();
}

class _ToolRunState extends State<_ToolRun> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final failed = widget.messages.where((m) => m.isError).length;
    final names = <String>{};
    for (final m in widget.messages) {
      final name = m.toolName;
      if (name != null && name.isNotEmpty) names.add(name);
    }
    final summary = names.isEmpty
        ? 'Tool activity'
        : names.take(2).join(', ') +
              (names.length > 2 ? ' +${names.length - 2}' : '');
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: c.rule),
        borderRadius: BorderRadius.circular(Radii.row),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            borderRadius: BorderRadius.circular(Radii.row),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.sm,
                vertical: Space.sm,
              ),
              child: Row(
                children: [
                  Icon(Icons.rule_folder_outlined, size: 15, color: c.muted),
                  const SizedBox(width: Space.xs),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: _highlightSpans(
                          '${widget.messages.length} tool ${widget.messages.length == 1 ? 'call' : 'calls'} · $summary',
                          widget.query,
                          monoStyle(context, size: 11, color: c.muted),
                          c.accent.withValues(alpha: 0.3),
                        ),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (failed > 0)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Text(
                        '$failed failed',
                        style: monoStyle(context, size: 10, color: c.accent),
                      ),
                    ),
                  Icon(
                    _open ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: c.muted,
                  ),
                ],
              ),
            ),
          ),
          if (_open)
            // header stays visible: a run can hold hundreds of calls
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.55,
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < widget.messages.length; i++) ...[
                      Divider(color: c.rule, height: 1),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          Space.sm,
                          Space.xs,
                          Space.sm,
                          Space.xs,
                        ),
                        child: _ToolCard(message: widget.messages[i]),
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// history window drops reasoning; this reads the ATIF trajectory once
class _ReasoningGroup extends StatefulWidget {
  const _ReasoningGroup({
    required this.steps,
    required this.busy,
    required this.onClose,
  });

  final List<String> steps;
  final bool busy;
  final VoidCallback onClose;

  @override
  State<_ReasoningGroup> createState() => _ReasoningGroupState();
}

class _ReasoningGroupState extends State<_ReasoningGroup> {
  /// only the latest steps show; older ones wait behind an explicit expand
  static const _latest = 3;

  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final steps = widget.steps;
    final shown = _all || steps.length <= _latest
        ? steps
        : steps.sublist(steps.length - _latest);
    final hidden = steps.length - shown.length;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: c.rule),
        borderRadius: BorderRadius.circular(Radii.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: widget.onClose,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.md,
                vertical: Space.sm,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: LedgerLabel(
                      steps.isEmpty
                          ? 'reasoning'
                          : 'reasoning · ${steps.length}',
                    ),
                  ),
                  if (hidden > 0)
                    TextButton(
                      onPressed: () => setState(() => _all = true),
                      child: Text(
                        '+$hidden older',
                        style: monoStyle(context, size: 10, color: c.muted),
                      ),
                    )
                  else if (_all && steps.length > _latest)
                    TextButton(
                      onPressed: () => setState(() => _all = false),
                      child: Text(
                        'latest only',
                        style: monoStyle(context, size: 10, color: c.muted),
                      ),
                    ),
                  if (widget.busy)
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    )
                  else
                    Icon(Icons.expand_less, size: 16, color: c.muted),
                ],
              ),
            ),
          ),
          Divider(color: c.rule, height: 1),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.6,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(Space.md),
              child: steps.isEmpty
                  ? Text(
                      widget.busy
                          ? 'Reading the reasoning trace'
                          : 'No reasoning recorded for this session yet.',
                      style: monoStyle(context, size: 11, color: c.muted),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var i = 0; i < shown.length; i++) ...[
                          if (i > 0) const SizedBox(height: Space.sm),
                          SelectableText(
                            shown[i],
                            style: monoStyle(context, size: 11, color: c.muted),
                          ),
                        ],
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// only shown away from the newest turn; no auto-scroll surprises
class _LatestButton extends StatelessWidget {
  const _LatestButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: c.accent,
      borderRadius: BorderRadius.circular(Radii.row),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.row),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.arrow_downward, size: 14, color: c.paper),
              const SizedBox(width: 6),
              Text(
                'Latest',
                style: monoStyle(context, size: 11, color: c.paper),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final _urlPattern = RegExp(
  r'(?:(?:https?|ftp)://|www\.)[^\s<>"\`]+',
  caseSensitive: false,
);

Future<void> _openLink(String raw) async {
  final uri = Uri.tryParse(raw);
  if (uri == null || (!uri.hasScheme && !raw.startsWith('www.'))) return;
  final target = raw.startsWith('www.') ? Uri.parse('https://$raw') : uri;
  if (kIsWeb) {
    platform.openExternalLink(target);
    return;
  }
  await launchUrl(target, mode: LaunchMode.externalApplication);
}

List<TextSpan> _plainSpans(
  String text,
  String query,
  TextStyle style,
  Color background,
) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return [TextSpan(text: text, style: style)];
  final lower = text.toLowerCase();
  final spans = <TextSpan>[];
  var start = 0;
  while (true) {
    final at = lower.indexOf(needle, start);
    if (at < 0) break;
    if (at > start) {
      spans.add(TextSpan(text: text.substring(start, at), style: style));
    }
    spans.add(
      TextSpan(
        text: text.substring(at, at + needle.length),
        style: style.copyWith(backgroundColor: background),
      ),
    );
    start = at + needle.length;
  }
  if (start < text.length) {
    spans.add(TextSpan(text: text.substring(start), style: style));
  }
  return spans.isEmpty ? [TextSpan(text: text, style: style)] : spans;
}

/// splits [text] around URLs (tappable) and case-insensitive [query] hits
List<TextSpan> _highlightSpans(
  String text,
  String query,
  TextStyle style,
  Color background,
) {
  final spans = <TextSpan>[];
  var start = 0;
  for (final match in _urlPattern.allMatches(text)) {
    if (match.start > start) {
      spans.addAll(
        _plainSpans(
          text.substring(start, match.start),
          query,
          style,
          background,
        ),
      );
    }
    final url = match.group(0)!;
    final recognizer = TapGestureRecognizer()..onTap = () => _openLink(url);
    spans.add(
      TextSpan(
        text: url,
        style: style.copyWith(
          color: style.color,
          decoration: TextDecoration.underline,
        ),
        recognizer: recognizer,
      ),
    );
    start = match.end;
  }
  if (start < text.length) {
    spans.addAll(_plainSpans(text.substring(start), query, style, background));
  }
  return spans.isEmpty ? [TextSpan(text: text, style: style)] : spans;
}

/// marks search hits inside Markdown without altering the source text
class _SearchHighlightSyntax extends md.InlineSyntax {
  _SearchHighlightSyntax(String query)
    : super(RegExp.escape(query.trim()), caseSensitive: false);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.text('mark', match[0]!));
    return true;
  }
}

class _SearchHighlightBuilder extends MarkdownElementBuilder {
  _SearchHighlightBuilder(this.background);

  final Color background;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    return Text.rich(
      TextSpan(
        text: element.textContent,
        style: (parentStyle ?? DefaultTextStyle.of(context).style).copyWith(
          backgroundColor: background,
        ),
      ),
    );
  }
}

class _MessageBlock extends StatelessWidget {
  const _MessageBlock({required this.message, this.query = ''});

  final AgentMessage message;
  final String query;

  @override
  Widget build(BuildContext context) {
    if (message.isTool || (message.kind == 'error' && !message.isUser)) {
      return _ToolCard(message: message, query: query);
    }
    final c = context.colors;
    final user = message.isUser;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LedgerLabel(user ? 'you' : 'agent', color: user ? c.muted : c.accent),
        const SizedBox(height: Space.xs),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(Space.md),
          decoration: BoxDecoration(
            color: user ? null : c.surface,
            border: Border.all(
              color: user ? c.rule : c.rule.withValues(alpha: 0.6),
            ),
            borderRadius: BorderRadius.circular(Radii.card),
          ),
          child: user
              ? _UserBody(text: message.text, query: query)
              : MarkdownBody(
                  data: message.text,
                  selectable: true,
                  onTapLink: (_, href, _) {
                    if (href != null) unawaited(_openLink(href));
                  },
                  styleSheet: _markdownStyle(context),
                  extensionSet: query.isEmpty
                      ? md.ExtensionSet.gitHubFlavored
                      : md.ExtensionSet(
                          md.ExtensionSet.gitHubFlavored.blockSyntaxes,
                          [
                            _SearchHighlightSyntax(query),
                            ...md.ExtensionSet.gitHubFlavored.inlineSyntaxes,
                          ],
                        ),
                  builders: {
                    'pre': MermaidMarkdownBuilder(),
                    if (query.isNotEmpty)
                      'mark': _SearchHighlightBuilder(
                        context.colors.accent.withValues(alpha: 0.3),
                      ),
                  },
                ),
        ),
      ],
    );
  }
}

/// staged file paths are plumbing; they read as attachments once sent
final _stagedPathPattern = RegExp(
  r'''['"]?(/[^\s'"]*/upload-[A-Za-z0-9]{6,}/[^\s'"]*)['"]?''',
);

class _UserBody extends StatelessWidget {
  const _UserBody({required this.text, this.query = ''});

  final String text;
  final String query;

  @override
  Widget build(BuildContext context) {
    final names = <String>[];
    final rest = text.replaceAllMapped(_stagedPathPattern, (m) {
      final path = m.group(1)!;
      names.add(path.split('/').last);
      return '';
    }).trim();
    final body = monoStyle(context, size: 12.5);
    final highlight = context.colors.accent.withValues(alpha: 0.3);
    if (names.isEmpty) {
      return MarkdownBody(
        data: text,
        selectable: true,
        styleSheet: _markdownStyle(context),
        extensionSet: md.ExtensionSet.gitHubFlavored,
        builders: {'pre': MermaidMarkdownBuilder()},
        onTapLink: (_, href, _) {
          if (href != null) unawaited(_openLink(href));
        },
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (rest.isNotEmpty) ...[
          SelectableText.rich(
            TextSpan(children: _highlightSpans(rest, query, body, highlight)),
            style: body,
          ),
          const SizedBox(height: Space.sm),
        ],
        Wrap(
          spacing: Space.xs,
          runSpacing: Space.xs,
          children: [for (final name in names) _AttachmentTag(name: name)],
        ),
      ],
    );
  }
}

class _AttachmentTag extends StatelessWidget {
  const _AttachmentTag({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: 4),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.rule),
        borderRadius: BorderRadius.circular(Radii.row),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.attach_file, size: 13, color: c.muted),
          const SizedBox(width: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: monoStyle(context, size: 11),
            ),
          ),
        ],
      ),
    );
  }
}

/// colours come from theme tokens so both palettes work
MarkdownStyleSheet _markdownStyle(BuildContext context) {
  final c = context.colors;
  final body = monoStyle(context, size: 12.5);
  final base = MarkdownStyleSheet();
  return base.copyWith(
    p: body,
    h1: nameStyle(context, size: 19),
    h2: nameStyle(context, size: 17),
    h3: nameStyle(context, size: 15.5),
    strong: body.copyWith(fontWeight: FontWeight.w700),
    em: body.copyWith(fontStyle: FontStyle.italic),
    listBullet: body,
    blockquote: monoStyle(context, size: 12, color: c.muted),
    blockquoteDecoration: BoxDecoration(
      color: c.surface,
      border: Border(left: BorderSide(color: c.rule, width: 2)),
    ),
    blockquotePadding: const EdgeInsets.fromLTRB(
      Space.md,
      Space.sm,
      Space.sm,
      Space.sm,
    ),
    code: monoStyle(
      context,
      size: 11.5,
      color: c.ink,
    ).copyWith(backgroundColor: c.paper),
    codeblockPadding: const EdgeInsets.all(Space.sm),
    codeblockDecoration: BoxDecoration(
      color: c.paper,
      border: Border.all(color: c.rule),
      borderRadius: BorderRadius.circular(Radii.row),
    ),
    tableBorder: TableBorder.all(color: c.rule, width: 0.7),
    tableHead: monoStyle(
      context,
      size: 11,
      color: c.muted,
    ).copyWith(fontWeight: FontWeight.w600),
    tableBody: monoStyle(context, size: 11.5),
    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    a: TextStyle(color: c.accent, decoration: TextDecoration.underline),
  );
}

/// collapsed to one line so long tool output doesn't bury the conversation
class _ToolCard extends StatefulWidget {
  const _ToolCard({required this.message, this.query = ''});

  final AgentMessage message;
  final String query;

  @override
  State<_ToolCard> createState() => _ToolCardState();
}

class _ToolCardState extends State<_ToolCard> {
  bool _open = false;
  bool _loading = false;
  String? _payload;
  String? _error;

  String get _body => _payload ?? widget.message.text;

  /// tool payloads arrive as a byte count only; the text is one RPC away
  Future<void> _toggle() async {
    final needsFetch =
        _body.trim().isEmpty &&
        widget.message.textBytes != null &&
        widget.message.id.isNotEmpty;
    if (!needsFetch) {
      setState(() => _open = !_open);
      return;
    }
    if (_open) {
      setState(() => _open = false);
      return;
    }
    setState(() {
      _open = true;
      _loading = true;
      _error = null;
    });
    try {
      final screen = context.findAncestorWidgetOfExactType<ChatScreen>();
      if (screen == null) throw BridgeError('No pane attached');
      final r = await AppScope.of(context).bridge!.historyEntry(
        entryId: widget.message.id,
        paneId: screen.pane.paneId,
        terminalId: screen.pane.terminalId,
      );
      if (!mounted) return;
      setState(() {
        _payload = (r['text'] as String?) ?? '';
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final m = widget.message;
    final failed = m.isError || m.kind == 'error';
    final label = switch (m.kind) {
      'tool_call' => 'CALL',
      'tool_result' => 'RESULT',
      'error' => 'ERROR',
      _ => m.kind.toUpperCase(),
    };
    final name = (m.toolName == null || m.toolName!.isEmpty)
        ? 'tool'
        : m.toolName!;
    final body = _body;
    final lines = body.trimRight().split('\n');
    final preview = lines.isEmpty || body.isEmpty
        ? (m.textBytes == null ? '' : '${m.textBytes} bytes · tap to load')
        : lines.first;
    final tint = failed ? c.accent : c.muted;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: (body.trim().isEmpty && m.textBytes == null) ? null : _toggle,
          borderRadius: BorderRadius.circular(Radii.row),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: Space.sm,
              vertical: 8,
            ),
            decoration: BoxDecoration(
              color: failed ? c.surface : null,
              border: Border.all(
                color: failed ? c.accent.withValues(alpha: 0.4) : c.rule,
              ),
              borderRadius: BorderRadius.circular(Radii.row),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  failed
                      ? Icons.error_outline
                      : (m.kind == 'tool_call'
                            ? Icons.build_outlined
                            : Icons.subdirectory_arrow_right),
                  size: 14,
                  color: tint,
                ),
                const SizedBox(width: Space.sm),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '$label ',
                          style: monoStyle(
                            context,
                            size: 9.5,
                            color: tint,
                          ).copyWith(letterSpacing: 0.8),
                        ),
                        ..._highlightSpans(
                          name,
                          widget.query,
                          monoStyle(
                            context,
                            size: 11.5,
                            color: failed ? c.accent : c.ink,
                          ),
                          c.accent.withValues(alpha: 0.3),
                        ),
                      ],
                    ),
                    maxLines: _open ? null : 1,
                    overflow: _open ? null : TextOverflow.ellipsis,
                  ),
                ),
                if (body.trim().isNotEmpty || m.textBytes != null)
                  _loading
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 1.4),
                        )
                      : Icon(
                          _open ? Icons.expand_less : Icons.expand_more,
                          size: 16,
                          color: c.muted,
                        ),
              ],
            ),
          ),
        ),
        if (!_open && preview.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: Space.md + 14, top: 3),
            child: Text.rich(
              TextSpan(
                children: _highlightSpans(
                  preview,
                  widget.query,
                  monoStyle(context, size: 10.5, color: c.muted),
                  c.accent.withValues(alpha: 0.3),
                ),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        if (_open)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: Space.xs),
            padding: const EdgeInsets.all(Space.sm),
            decoration: BoxDecoration(
              color: c.surface,
              border: Border.all(color: c.rule),
              borderRadius: BorderRadius.circular(Radii.row),
            ),
            child: _loading
                ? Text(
                    'Loading payload',
                    style: monoStyle(context, size: 11, color: c.muted),
                  )
                : _error != null
                ? SelectableText(
                    _error!,
                    style: monoStyle(context, size: 11, color: c.accent),
                  )
                : _ToolPayload(text: _body, query: widget.query),
          ),
      ],
    );
  }
}

/// file edits arrive as unified diffs; paint +/- lines inside the same card
class _ToolPayload extends StatelessWidget {
  const _ToolPayload({required this.text, this.query = ''});

  final String text;
  final String query;

  bool get _isDiff {
    final lines = text.split('\n');
    return lines.any((l) => l.startsWith('@@')) ||
        lines.any((l) => l.startsWith('diff --git')) ||
        (lines.where((l) => l.startsWith('+') && !l.startsWith('+++')).length +
                lines
                    .where((l) => l.startsWith('-') && !l.startsWith('---'))
                    .length) >
            2;
  }

  @override
  Widget build(BuildContext context) {
    if (!_isDiff) {
      return SelectableText.rich(
        TextSpan(
          children: _highlightSpans(
            text,
            query,
            monoStyle(context, size: 11),
            context.colors.accent.withValues(alpha: 0.3),
          ),
        ),
        style: monoStyle(context, size: 11),
      );
    }
    final base = monoStyle(context, size: 10.5);
    final highlight = context.colors.accent.withValues(alpha: 0.3);
    final spans = <TextSpan>[];
    for (final line in text.split('\n')) {
      final added = line.startsWith('+') && !line.startsWith('+++');
      final removed = line.startsWith('-') && !line.startsWith('---');
      final style = base.copyWith(
        color: added
            ? const Color(0xFF3E7D3E)
            : removed
            ? const Color(0xFFB4502B)
            : null,
        backgroundColor: added
            ? const Color(0x1A8FA968)
            : removed
            ? const Color(0x1AD9642F)
            : null,
      );
      spans.addAll(_highlightSpans('$line\n', query, style, highlight));
    }
    return SelectableText.rich(TextSpan(children: spans));
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.sending,
    required this.active,
    required this.onSend,
    required this.onInterrupt,
    required this.onAttach,
    required this.attaching,
    required this.staged,
    required this.onRemove,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool sending;
  final bool active;
  final VoidCallback onSend;
  final VoidCallback onInterrupt;
  final VoidCallback onAttach;
  final bool attaching;
  final List<StagedFile> staged;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: c.paper,
        border: Border(top: BorderSide(color: c.rule)),
      ),
      padding: const EdgeInsets.fromLTRB(Space.sm, Space.sm, Space.sm, 0),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (staged.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Space.xs,
                  0,
                  Space.xs,
                  Space.xs,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: Space.xs,
                    runSpacing: Space.xs,
                    children: [
                      for (var i = 0; i < staged.length; i++)
                        _StagedChip(
                          name: staged[i].name,
                          onRemove: () => onRemove(i),
                        ),
                    ],
                  ),
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  onPressed: attaching ? null : onAttach,
                  color: c.ink,
                  tooltip: 'Attach a file',
                  icon: attaching
                      ? SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.6,
                            color: c.ink,
                          ),
                        )
                      : const Icon(Icons.attach_file, size: 20),
                ),
                Expanded(
                  child: TextField(
                    controller: controller,
                    focusNode: focusNode,
                    minLines: 1,
                    maxLines: 5,
                    style: monoStyle(context, size: 13),
                    textInputAction: TextInputAction.newline,
                    decoration: InputDecoration(
                      hintText: 'Message the agent',
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
                IconButton(
                  onPressed: onInterrupt,
                  color: active ? c.accent : c.muted,
                  tooltip: 'Interrupt (Esc)',
                  icon: const Icon(Icons.stop_circle_outlined, size: 20),
                ),
                const SizedBox(width: Space.xs),
                SizedBox(
                  height: 44,
                  width: 44,
                  child: IconButton.filled(
                    onPressed: sending ? null : onSend,
                    style: IconButton.styleFrom(
                      backgroundColor: c.ink,
                      foregroundColor: c.paper,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(Radii.row),
                      ),
                    ),
                    tooltip: 'Send',
                    icon: sending
                        ? SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.6,
                              color: c.paper,
                            ),
                          )
                        : const Icon(Icons.arrow_upward, size: 18),
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

/// the agent receives the remote path; the chip shows only the picked name
class _StagedChip extends StatelessWidget {
  const _StagedChip({required this.name, required this.onRemove});

  final String name;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(Space.sm, 4, 4, 4),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.rule),
        borderRadius: BorderRadius.circular(Radii.row),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.attach_file, size: 13, color: c.muted),
          const SizedBox(width: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 200),
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: monoStyle(context, size: 11),
            ),
          ),
          InkWell(
            onTap: onRemove,
            borderRadius: BorderRadius.circular(Radii.row),
            child: Padding(
              padding: const EdgeInsets.all(3),
              child: Icon(Icons.close, size: 13, color: c.muted),
            ),
          ),
        ],
      ),
    );
  }
}

/// staged files live on the bridge host; only paths must survive a switch
class _Draft {
  _Draft(this.text, this.staged);
  final String text;
  final List<StagedFile> staged;
}

class _DraftStore {
  static final _memory = <String, _Draft>{};

  static Future<_Draft?> load(String key) async {
    final warm = _memory[key];
    if (warm != null) return warm;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final staged = <StagedFile>[];
      for (final f in (j['staged'] as List? ?? const [])) {
        if (f is! Map) continue;
        final path = f['path'] as String?;
        if (path == null || path.isEmpty) continue;
        staged.add(
          StagedFile(
            path: path,
            name: (f['name'] as String?) ?? path.split('/').last,
            size: (f['size'] as num?)?.toInt() ?? 0,
          ),
        );
      }
      final draft = _Draft((j['text'] as String?) ?? '', staged);
      _memory[key] = draft;
      return draft;
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(
    String key,
    String text,
    List<StagedFile> staged,
  ) async {
    if (text.isEmpty && staged.isEmpty) {
      await clear(key);
      return;
    }
    final draft = _Draft(text, List.of(staged));
    _memory[key] = draft;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      key,
      jsonEncode({
        'text': text,
        'staged': [
          for (final f in staged)
            {'path': f.path, 'name': f.name, 'size': f.size},
        ],
      }),
    );
  }

  static Future<void> clear(String key) async {
    _memory.remove(key);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);
  }
}

/// warm reopen without a spinner; bounded by the bridge's 200-entry window
class _TranscriptCache {
  static final _memory = <String, List<AgentMessage>>{};
  static const _limit = 60;
  static const _textLimit = 4000;

  static List<AgentMessage>? memory(String key) => _memory[key];

  static Future<List<AgentMessage>> load(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null) return const [];
    try {
      return (jsonDecode(raw) as List)
          .cast<Map<String, dynamic>>()
          .map(
            (m) => AgentMessage(
              id: (m['id'] as String?) ?? '',
              role: (m['role'] as String?) ?? 'assistant',
              kind: (m['kind'] as String?) ?? 'message',
              text: (m['text'] as String?) ?? '',
              toolName: m['tool_name'] as String?,
              isError: m['is_error'] == true,
              textBytes: (m['text_bytes'] as num?)?.toInt(),
              sentAt: m['sent_at'] as String?,
            ),
          )
          .where((m) => m.kind != 'reasoning')
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> save(String key, List<AgentMessage> messages) async {
    final tail = messages.length <= _limit
        ? messages
        : messages.sublist(messages.length - _limit);
    _memory[key] = tail;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      key,
      jsonEncode([
        for (final m in tail)
          {
            'id': m.id,
            'role': m.role,
            'kind': m.kind,
            'text': m.text.length <= _textLimit
                ? m.text
                : m.text.substring(0, _textLimit),
            'tool_name': m.toolName,
            'is_error': m.isError,
            'text_bytes': m.textBytes,
            'sent_at': m.sentAt,
          },
      ]),
    );
  }
}
