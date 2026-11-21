import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:xterm/xterm.dart' hide TerminalKey;
import 'package:xterm/xterm.dart' as xt show TerminalKey;

import '../bridge/bridge.dart';
import '../model/app_state.dart';
import '../model/keybar.dart';
import '../theme/tokens.dart';
import 'chat_screen.dart';
import 'key_bar.dart';
import 'widgets.dart';

/// xterm's default keytab has no bare Space record, so shift+space (IME
/// shifted key events) is swallowed; emit the space before the keytab runs.
final drovesInputHandler = CascadeInputHandler([
  _SpaceInputHandler(),
  defaultInputHandler,
]);

class _SpaceInputHandler implements TerminalInputHandler {
  @override
  String? call(TerminalKeyboardEvent event) {
    if (event.key == xt.TerminalKey.space && !event.ctrl && !event.alt) {
      return ' ';
    }
    return null;
  }
}

/// server renders ANSI; scrollback arrives as a separate `history` payload
/// that must land in the buffer before frames or the pane looks empty
class TerminalScreen extends StatefulWidget {
  const TerminalScreen({
    super.key,
    required this.pane,
    required this.workspaceLabel,
  });

  final PaneInfo pane;
  final String workspaceLabel;

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  // agent detection lands after the pane opens; poll agent.list so the chat
  // button appears without leaving the terminal
  String? _agent;
  String _agentStatus = 'unknown';
  Timer? _agentPoll;
  late final Terminal _terminal;
  late final TerminalController _controller;
  final _scroll = ScrollController();
  final _focus = FocusNode();
  StreamSubscription<TerminalFrame>? _sub;
  List<String> _keyIds = defaultKeyIds;
  final Set<String> _latched = {};
  bool _attached = false;
  bool _uploading = false;
  int _scrollOffset = 0;
  bool _showKeyBar = false;
  bool _hasSelection = false;
  bool _split = false;
  int _wideCols = 0;
  int _wideRows = 0;
  String _message = 'Opening terminal';

  // initState/dispose can't touch inherited widgets; resolve once here
  Bridge? _bridgeRef;
  Bridge get _bridge => _bridgeRef!;

  @override
  void initState() {
    super.initState();
    _agent = widget.pane.agent;
    _agentStatus = widget.pane.agentStatus;
    _terminal = Terminal(maxLines: 20000, inputHandler: drovesInputHandler);
    _controller = TerminalController();
    _terminal.onOutput = (data) {
      _pushGrid();
      _bridge
          .input(widget.pane.terminalId, _applyModifiers(data))
          .catchError((_) {});
    };
    // a single pane owns the layout, so its grid follows the screen; a split
    // pane mirrors herdr's grid and must never push a resize
    _terminal.onResize = (cols, rows, pw, ph) {
      if (_attached && !_split) _pushGrid(cols, rows);
    };
    _controller.addListener(() {
      if (!mounted) return;
      final has = _controller.selection != null;
      if (has != _hasSelection) setState(() => _hasSelection = has);
    });
    _restoreKeyBar();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_bridgeRef != null) return;
    _bridgeRef = AppScope.of(context).bridge;
    if (_bridgeRef != null) {
      _attach();
      _startAgentPoll();
    }
  }

  Future<void> _restoreKeyBar() async {
    final ids = await KeyBarPrefs.loadKeys();
    final enabled = await KeyBarPrefs.loadEnabled();
    if (!mounted) return;
    setState(() {
      _keyIds = ids;
      _showKeyBar = enabled;
    });
  }

  Future<void> _attach() async {
    if (_bridgeRef == null) return;
    try {
      _sub = _bridge.frames
          .where((f) => f.terminalId == widget.pane.terminalId)
          .listen((frame) {
            // the viewer always mirrors herdr's grid, split or not, and never
            // pushes a resize back
            if (_split &&
                frame.full &&
                frame.width > 0 &&
                frame.height > 0 &&
                (frame.width != _wideCols ||
                    frame.height != _wideRows ||
                    frame.split != _split)) {
              if (mounted) {
                setState(() {
                  _split = frame.split;
                  _wideCols = frame.width;
                  _wideRows = frame.height;
                });
              }
              _terminal.resize(frame.width, frame.height);
            }
            _terminal.write(frame.bytes);
            if (!_attached && mounted) setState(() => _attached = true);
          });
      final attachment = await _bridge.attach(
        widget.pane.terminalId,
        _terminal.viewWidth,
        _terminal.viewHeight,
      );
      if (!mounted) return;
      if (attachment.split && attachment.cols > 0 && attachment.rows > 0) {
        _terminal.resize(attachment.cols, attachment.rows);
      } else {
        // pre-attach onResize events were dropped; push the settled viewport so
        // the bridge renders rows at the width xterm is actually drawing
        await _bridge
            .resize(
              widget.pane.terminalId,
              _terminal.viewWidth,
              _terminal.viewHeight,
            )
            .catchError((_) {});
      }
      if (!mounted) return;
      setState(() {
        _scrollOffset = attachment.offset;
        _split = attachment.split;
        _wideCols = attachment.cols;
        _wideRows = attachment.rows;
        _attached = true;
        _message = '';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = e.toString());
    }
  }

  @override
  void dispose() {
    _agentPoll?.cancel();
    _sub?.cancel();
    if (_attached) {
      _bridgeRef?.detach(widget.pane.terminalId).catchError((_) {});
    }
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _startAgentPoll() {
    _refreshAgent();
    _agentPoll ??= Timer.periodic(const Duration(seconds: 4), (_) {
      _refreshAgent();
    });
  }

  Future<void> _refreshAgent() async {
    final live = _bridgeRef;
    if (live == null || live.state != BridgeState.ready) return;
    try {
      final r = await live.call('agent.list', {});
      final agents = (r['agents'] as List?) ?? const [];
      String? agent;
      var status = 'unknown';
      for (final raw in agents) {
        final a = (raw as Map).cast<String, dynamic>();
        if (a['terminal_id'] == widget.pane.terminalId) {
          agent = a['agent'] as String?;
          status = (a['agent_status'] as String?) ?? 'unknown';
          break;
        }
      }
      if (!mounted) return;
      if (agent != _agent || status != _agentStatus) {
        setState(() {
          _agent = agent;
          _agentStatus = status;
        });
      }
    } catch (_) {
      // transient bridge errors are fine; the next tick retries
    }
  }

  void _send(TerminalKey key) {
    if (key.sticky) {
      setState(() {
        if (!_latched.remove(key.id)) _latched.add(key.id);
      });
      _focus.requestFocus();
      return;
    }
    _bridge.input(widget.pane.terminalId, key.sequence).catchError((_) {});
    _focus.requestFocus();
  }

  /// sticky modifiers latch for one printable character, then clear
  String _applyModifiers(String data) {
    final out = applyStickyModifiers(_latched, data);
    if (_latched.isNotEmpty && data.length == 1) {
      _latched.clear();
      if (mounted) setState(() {});
    }
    return out;
  }

  Future<void> _toggleKeyBar() async {
    final next = !_showKeyBar;
    setState(() => _showKeyBar = next);
    await KeyBarPrefs.saveEnabled(next);
  }

  Future<void> _configureKeys() async {
    final picked = await showModalBottomSheet<List<String>>(
      context: context,
      backgroundColor: context.colors.paper,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.card)),
      ),
      builder: (_) => KeyBarPickerSheet(selected: _keyIds),
    );
    if (picked == null) return;
    setState(() => _keyIds = picked);
    await KeyBarPrefs.saveKeys(picked);
    if (!mounted) return;
    await KeyBarPrefs.saveEnabled(true);
    setState(() => _showKeyBar = true);
  }

  /// types the staged path without Enter so it can join a composed command
  Future<void> _attachFile() async {
    final file = await FilePicker.pickFile(type: FileType.any);
    if (file == null) return;
    setState(() => _uploading = true);
    try {
      final bytes = await file.readAsBytes();
      final staged = await _bridge.upload(file.name, bytes);
      await _bridge.paste(widget.pane.terminalId, '${staged.path} ');
      _focus.requestFocus();
      _toast('Attached ${staged.name}');
    } catch (e) {
      _toast('Could not attach: $e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  /// bracketed paste through the bridge; works with the soft keyboard closed
  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) {
      _toast('Clipboard is empty');
      return;
    }
    try {
      await _bridge.paste(widget.pane.terminalId, text);
      _focus.requestFocus();
    } catch (e) {
      _toast(e.toString());
    }
  }

  Future<void> _copySelection() async {
    final selection = _controller.selection;
    if (selection == null) return;
    final text = _terminal.buffer.getText(selection);
    if (text.isEmpty) {
      _toast('Nothing selected');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    _controller.clearSelection();
    _focus.requestFocus();
    _toast('Copied');
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message, style: monoStyle(context, size: 12))),
    );
  }

  /// scrollback lives on the server; drags become scroll RPCs
  void _serverScroll(int lines) {
    if (lines == 0) return;
    _pushGrid();
    _bridge
        .scroll(widget.pane.terminalId, lines, up: lines < 0)
        .then((offset) {
          if (!mounted) return;
          setState(() => _scrollOffset = offset);
        })
        .catchError((_) {});
  }

  /// The bridge keeps one grid per terminal session, so a tablet/laptop resize
  /// would otherwise leave this device sending nothing on its next interaction.
  /// Re-assert this view's grid every time the user scrolls or types.
  void _pushGrid([int? cols, int? rows]) {
    if (!_attached || _split) return;
    final c = cols ?? _terminal.viewWidth;
    final r = rows ?? _terminal.viewHeight;
    if (c < 2 || r < 2) return;
    _bridge.resize(widget.pane.terminalId, c, r).catchError((_) {});
  }

  void _scrollToBottom() {
    // ask the server for the live tail; a local jump only moves the widget
    _bridge
        .scroll(widget.pane.terminalId, 1 << 20, up: false)
        .then((offset) {
          if (!mounted) return;
          setState(() => _scrollOffset = offset);
        })
        .catchError((_) {});
    if (!kIsWeb && _scroll.hasClients) {
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final agent = _agent;
    return DrovesScaffold(
      title: widget.workspaceLabel,
      subtitle: Row(
        children: [
          StatusWord(_agentStatus),
          const SizedBox(width: Space.sm),
          Flexible(
            child: Text(
              _shortCwd(widget.pane.cwd),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: monoStyle(context, size: 10, color: c.muted),
            ),
          ),
        ],
      ),
      leading: IconButton(
        icon: const Icon(Icons.arrow_back, size: 20),
        color: c.ink,
        onPressed: () => Navigator.of(context).maybePop(),
        tooltip: 'Back to workspaces',
      ),
      actions: [
        if (agent != null && agent.isNotEmpty)
          IconButton(
            icon: const Icon(Icons.chat_bubble_outline, size: 20),
            color: c.ink,
            tooltip: 'Chat',
            // replace the route so chat/terminal swaps never grow the back stack
            onPressed: () => Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                builder: (_) =>
                    ChatScreen(pane: widget.pane, label: widget.workspaceLabel),
              ),
            ),
          ),
        IconButton(
          icon: _uploading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.attach_file, size: 20),
          color: c.ink,
          tooltip: 'Attach a file',
          onPressed: _uploading ? null : _attachFile,
        ),
        IconButton(
          icon: const Icon(Icons.content_paste_go, size: 20),
          color: c.ink,
          tooltip: 'Paste from clipboard',
          onPressed: _pasteFromClipboard,
        ),
        if (_hasSelection)
          IconButton(
            icon: const Icon(Icons.copy, size: 20),
            color: c.accent,
            tooltip: 'Copy selection',
            onPressed: _copySelection,
          ),
        IconButton(
          icon: Icon(
            _showKeyBar ? Icons.keyboard_alt : Icons.keyboard_alt_outlined,
            size: 20,
          ),
          color: _showKeyBar ? c.accent : c.ink,
          tooltip: _showKeyBar ? 'Hide shortcuts' : 'Show shortcuts',
          onPressed: _toggleKeyBar,
        ),
      ],
      // in the body column, Scaffold's bottom inset keeps it above the keyboard
      child: Column(
        children: [
          Expanded(
            child: ColoredBox(
              color: c.terminalBg,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        // fill the pane: a narrow split pane grows its font, a
                        // wide grid shrinks it; whichever side runs out first
                        // decides, so the grid always fits without clipping
                        final usableHeight =
                            constraints.maxHeight -
                            MediaQuery.paddingOf(context).vertical;
                        final byWidth = _wideCols > 0
                            ? (constraints.maxWidth - 4) / (_wideCols * 0.6)
                            : 12.0;
                        final byHeight = _wideRows > 0
                            ? usableHeight / _wideRows / 1.2
                            : 12.0;
                        final fit = byWidth < byHeight ? byWidth : byHeight;
                        // a split pane scales its whole grid down to fit; a
                        // single pane keeps normal text and xterm's own grid
                        final fontSize = _split
                            ? fit.clamp(2.0, 12.0).toDouble()
                            : 12.0;
                        final lineHeight = _split && _wideRows > 0
                            ? (usableHeight / _wideRows / fontSize).clamp(
                                1.2,
                                8.0,
                              )
                            : 1.2;
                        return TerminalView(
                          _terminal,
                          controller: _controller,
                          scrollController: _scroll,
                          focusNode: _focus,
                          theme: _terminalTheme(c),
                          textScaler: TextScaler.noScaling,
                          textStyle: TerminalStyle(
                            fontSize: fontSize.toDouble(),
                            height: lineHeight.toDouble(),
                            fontFamily: 'JetBrainsMonoNerd',
                            fontFamilyFallback: const [
                              'JetBrainsMonoNerd',
                              'PlexMono',
                              'NotoColorEmoji',
                            ],
                          ),
                          autoResize: !_split,
                          keyboardType: TextInputType.text,
                          autofocus: false,
                          // drags scroll the scrollback instead of feeding mouse reporting
                          simulateScroll: true,
                          backgroundOpacity: 1,
                        );
                      },
                    ),
                  ),
                  if (!_attached)
                    ColoredBox(
                      color: c.terminalBg,
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(Space.lg),
                          child: Text(
                            _message,
                            textAlign: TextAlign.center,
                            style: monoStyle(
                              context,
                              size: 12,
                              color: c.terminalFg,
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (_attached)
                    Positioned.fill(
                      child: _ServerScrollCatcher(onScroll: _serverScroll),
                    ),
                  if (_attached && _scrollOffset > 0)
                    Positioned(
                      right: Space.sm,
                      bottom: Space.sm,
                      child: _ScrollToBottomButton(onTap: _scrollToBottom),
                    ),
                ],
              ),
            ),
          ),
          if (_showKeyBar)
            KeyBar(
              ids: _keyIds,
              active: _latched,
              onKey: _send,
              onConfigure: _configureKeys,
            ),
        ],
      ),
    );
  }

  static String _shortCwd(String? cwd) {
    if (cwd == null || cwd.isEmpty) return '';
    final parts = cwd.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.length <= 2) return cwd;
    return '…/${parts.sublist(parts.length - 2).join('/')}';
  }

  static TerminalTheme _terminalTheme(DrovesColors c) => TerminalTheme(
    cursor: c.terminalFg,
    selection: c.accent.withValues(alpha: 0.35),
    foreground: c.terminalFg,
    background: c.terminalBg,
    black: const Color(0xFF2A2622),
    white: const Color(0xFFEDE8DE),
    red: const Color(0xFFD9642F),
    green: const Color(0xFF8FA968),
    yellow: const Color(0xFFD9A94F),
    blue: const Color(0xFF7E9BB5),
    magenta: const Color(0xFFB08AA8),
    cyan: const Color(0xFF7FA9A2),
    brightBlack: const Color(0xFF6E675C),
    brightRed: const Color(0xFFE8834F),
    brightGreen: const Color(0xFFA8C47F),
    brightYellow: const Color(0xFFE8C06B),
    brightBlue: const Color(0xFF9BB6CE),
    brightMagenta: const Color(0xFFC9A2C0),
    brightCyan: const Color(0xFF9AC2BA),
    brightWhite: const Color(0xFFF7F3EA),
    searchHitBackground: const Color(0xFF3A332A),
    searchHitBackgroundCurrent: const Color(0xFF5A4A34),
    searchHitForeground: const Color(0xFFF7F3EA),
  );
}

class _ScrollToBottomButton extends StatelessWidget {
  const _ScrollToBottomButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: Colors.transparent,
      child: Tooltip(
        message: 'Go to latest',
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(Radii.row),
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c.terminalBg.withValues(alpha: 0.72),
              border: Border.all(color: c.terminalFg.withValues(alpha: 0.25)),
              borderRadius: BorderRadius.circular(Radii.row),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.arrow_downward, size: 14, color: c.terminalFg),
                const SizedBox(width: 6),
                Text(
                  'Latest',
                  style: monoStyle(context, size: 11, color: c.terminalFg),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// claims vertical drags for scroll RPCs; below the scroll-to-bottom button
class _ServerScrollCatcher extends StatefulWidget {
  const _ServerScrollCatcher({required this.onScroll});

  /// positive lines scroll toward the bottom, negative toward history
  final void Function(int lines) onScroll;

  @override
  State<_ServerScrollCatcher> createState() => _ServerScrollCatcherState();
}

class _ServerScrollCatcherState extends State<_ServerScrollCatcher> {
  double _carry = 0;

  void _feed(double dy) {
    _carry += dy;
    const lineHeight = 15.0;
    final whole = _carry ~/ lineHeight;
    if (whole == 0) return;
    _carry -= whole * lineHeight;
    // dragging down reveals older lines; negate for the RPC
    widget.onScroll(-whole);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      // Chrome Android turns touch drags into pan-zoom/wheel streams that
      // xterm's scrollable eats as arrow keys; consume them here first.
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) {
          GestureBinding.instance.pointerSignalResolver.register(event, (e) {
            _feed((e as PointerScrollEvent).scrollDelta.dy);
          });
        }
      },
      onPointerPanZoomUpdate: (event) => _feed(event.panDelta.dy),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragUpdate: (details) => _feed(details.delta.dy),
        onVerticalDragEnd: (_) => _carry = 0,
        onVerticalDragCancel: () => _carry = 0,
      ),
    );
  }
}
