import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart' hide TerminalKey;

import '../bridge/bridge.dart';
import '../model/app_state.dart';
import '../model/keybar.dart';
import '../theme/tokens.dart';
import 'chat_screen.dart';
import 'key_bar.dart';
import 'widgets.dart';

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
  late final Terminal _terminal;
  late final TerminalController _controller;
  final _scroll = ScrollController();
  final _focus = FocusNode();
  StreamSubscription<TerminalFrame>? _sub;
  List<String> _keyIds = defaultKeyIds;
  final Set<String> _latched = {};
  bool _attached = false;
  bool _uploading = false;
  bool _showKeyBar = false;
  String _message = 'Opening terminal';

  // initState/dispose can't touch inherited widgets; resolve once here
  Bridge? _bridgeRef;
  Bridge get _bridge => _bridgeRef!;

  @override
  void initState() {
    super.initState();
    _terminal = Terminal(maxLines: 20000);
    _controller = TerminalController();
    _terminal.onOutput = (data) {
      _bridge
          .input(widget.pane.terminalId, _applyModifiers(data))
          .catchError((_) {});
    };
    _terminal.onResize = (cols, rows, pw, ph) {
      if (_attached) {
        _bridge.resize(widget.pane.terminalId, cols, rows).catchError((_) {});
      }
    };
    _restoreKeyBar();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_bridgeRef != null) return;
    _bridgeRef = AppScope.of(context).bridge;
    if (_bridgeRef != null) _attach();
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
            // a frame repaints only the viewport; keep the `history` scrollback
            _terminal.write(frame.bytes);
            if (!_attached && mounted) setState(() => _attached = true);
          });
      await _bridge.attach(
        widget.pane.terminalId,
        _terminal.viewWidth,
        _terminal.viewHeight,
      );
      // pre-attach onResize events were dropped; push the settled viewport size
      await _bridge.resize(
        widget.pane.terminalId,
        _terminal.viewWidth,
        _terminal.viewHeight,
      );
      if (!mounted) return;
      setState(() {
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
    _sub?.cancel();
    if (_attached) {
      _bridgeRef?.detach(widget.pane.terminalId).catchError((_) {});
    }
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
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

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message, style: monoStyle(context, size: 12))),
    );
  }

  /// scrollback lives on the server; drags become scroll RPCs
  void _serverScroll(int lines) {
    if (lines == 0) return;
    _bridge
        .scroll(widget.pane.terminalId, lines, up: lines < 0)
        .catchError((_) {});
  }

  void _scrollToBottom() {
    // ask the server for the live tail; a local jump only moves the widget
    _bridge
        .scroll(widget.pane.terminalId, 1 << 20, up: false)
        .catchError((_) {});
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final agent = widget.pane.agent;
    return DrovesScaffold(
      title: widget.workspaceLabel,
      subtitle: Row(
        children: [
          StatusWord(widget.pane.agentStatus),
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
                  TerminalView(
                    _terminal,
                    controller: _controller,
                    scrollController: _scroll,
                    focusNode: _focus,
                    theme: _terminalTheme(c),
                    textStyle: const TerminalStyle(
                      fontSize: 12,
                      fontFamily: 'JetBrainsMonoNerd',
                      fontFamilyFallback: [
                        'JetBrainsMonoNerd',
                        'PlexMono',
                        'NotoColorEmoji',
                      ],
                    ),
                    keyboardType: TextInputType.text,
                    autofocus: false,
                    // drags scroll the scrollback instead of feeding mouse reporting
                    simulateScroll: true,
                    backgroundOpacity: 1,
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
                  if (_attached)
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

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragUpdate: (details) {
        _carry += details.delta.dy;
        const lineHeight = 15.0;
        final whole = _carry ~/ lineHeight;
        if (whole == 0) return;
        _carry -= whole * lineHeight;
        // dragging down reveals older lines; negate for the RPC
        widget.onScroll(-whole);
      },
      onVerticalDragEnd: (_) => _carry = 0,
      onVerticalDragCancel: () => _carry = 0,
    );
  }
}
