import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'decode.dart';
import 'socket.dart';

/// a terminal pane as the bridge reports it
class PaneInfo {
  PaneInfo({
    required this.paneId,
    required this.terminalId,
    required this.workspaceId,
    required this.tabId,
    required this.agentStatus,
    this.agent,
    this.cwd,
    this.title,
    this.focused = false,
  });

  final String paneId;
  final String terminalId;
  final String workspaceId;
  final String tabId;
  final String agentStatus;
  final String? agent;
  final String? cwd;
  final String? title;
  final bool focused;

  /// CLI titles carry private-use icon glyphs; list rows strip them,
  /// the terminal keeps the original
  static final _pua = RegExp(
    '[\\u{E000}-\\u{F8FF}]|[\\u{F0000}-\\u{FFFFD}]|[\\u{100000}-\\u{10FFFD}]',
    unicode: true,
  );

  String? get displayTitle {
    final raw = title?.replaceAll(_pua, '').trim();
    return (raw == null || raw.isEmpty)
        ? null
        : raw.replaceAll(RegExp(r'\s{2,}'), ' ');
  }

  String get titleOrCwd =>
      displayTitle ?? ((cwd?.isNotEmpty ?? false) ? cwd! : paneId);

  factory PaneInfo.fromJson(Map<String, dynamic> j) => PaneInfo(
    paneId: j['pane_id'] as String,
    terminalId: j['terminal_id'] as String,
    workspaceId: j['workspace_id'] as String,
    tabId: j['tab_id'] as String,
    agentStatus: (j['agent_status'] as String?) ?? 'unknown',
    agent: j['agent'] as String?,
    cwd: (j['foreground_cwd'] ?? j['cwd']) as String?,
    title: (j['terminal_title_stripped'] ?? j['terminal_title']) as String?,
    focused: j['focused'] == true,
  );
}

class WorkspaceInfo {
  WorkspaceInfo({
    required this.workspaceId,
    required this.label,
    required this.number,
    required this.paneCount,
    required this.tabCount,
    required this.agentStatus,
    this.cwd,
    this.activeTabId,
  });

  final String workspaceId;
  final String label;
  final int number;
  final int paneCount;
  final int tabCount;
  final String agentStatus;
  final String? cwd;
  final String? activeTabId;

  factory WorkspaceInfo.fromJson(Map<String, dynamic> j) => WorkspaceInfo(
    workspaceId: j['workspace_id'] as String,
    label: str(j['label']),
    number: integer(j['number']) ?? 0,
    paneCount: integer(j['pane_count']) ?? 0,
    tabCount: integer(j['tab_count']) ?? 0,
    agentStatus: (j['agent_status'] as String?) ?? 'unknown',
    cwd: j['cwd'] as String?,
    activeTabId: j['active_tab_id'] as String?,
  );
}

class TabInfo {
  TabInfo({
    required this.tabId,
    required this.workspaceId,
    required this.label,
    required this.number,
    required this.paneCount,
    required this.agentStatus,
  });

  final String tabId;
  final String workspaceId;
  final String label;
  final int number;
  final int paneCount;
  final String agentStatus;

  factory TabInfo.fromJson(Map<String, dynamic> j) => TabInfo(
    tabId: j['tab_id'] as String,
    workspaceId: j['workspace_id'] as String,
    label: str(j['label']),
    number: integer(j['number']) ?? 0,
    paneCount: integer(j['pane_count']) ?? 0,
    agentStatus: (j['agent_status'] as String?) ?? 'unknown',
  );
}

class TerminalFrame {
  TerminalFrame({
    required this.terminalId,
    required this.width,
    required this.height,
    required this.split,
    required this.full,
    required this.bytes,
  });

  final String terminalId;
  final int width;
  final int height;

  final bool split;
  final bool full;

  final String bytes;
}

enum BridgeState { idle, connecting, ready, failed }

/// HTTP login for a session cookie, then the bridge's own JSON-RPC `/ws` socket
class Bridge {
  Bridge(this.baseUrl);

  final Uri baseUrl;

  WebSocketChannel? _socket;
  String? _cookie;
  int _seq = 0;
  final Map<String, Completer<Map<String, dynamic>>> _pending = {};

  final _frames = StreamController<TerminalFrame>.broadcast();
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _state = StreamController<BridgeState>.broadcast();
  final _notices = StreamController<TaskNotice>.broadcast();

  Stream<TerminalFrame> get frames => _frames.stream;
  Stream<Map<String, dynamic>> get events => _events.stream;
  Stream<BridgeState> get stateStream => _state.stream;

  Stream<TaskNotice> get notices => _notices.stream;

  BridgeState _current = BridgeState.idle;
  BridgeState get state => _current;
  String? _lastError;
  String? get lastError => _lastError;
  String connectionId = 'legacy-default';

  void _setState(BridgeState s, [String? error]) {
    _current = s;
    _lastError = error;
    if (!_state.isClosed) _state.add(s);
  }

  Future<void> login(String password) async {
    final res = await http.post(
      bridgeUri(baseUrl, 'api/login'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'password': password}),
    );
    if (res.statusCode != 200) {
      throw BridgeError('Login rejected (${res.statusCode}). Check the token.');
    }
    if (kIsWeb) {
      _cookie = 'browser-managed';
      return;
    }
    final cookies = res.headers['set-cookie'];
    if (cookies == null || cookies.isEmpty) {
      throw BridgeError(
        'The bridge accepted the token but did not finish signing in.',
      );
    }
    _cookie = cookies.split(';').first;
  }

  Map<String, String> get _authHeaders =>
      kIsWeb || _cookie == null ? const {} : {'cookie': _cookie!};

  Future<void> connect(String password) async {
    _setState(BridgeState.connecting);
    try {
      await _socket?.sink.close();
      _socket = null;
      _helloCompleter = null;
      if (_cookie == null) await login(password);
      final wsUri = bridgeUri(
        baseUrl,
        'ws',
      ).replace(scheme: baseUrl.scheme == 'https' ? 'wss' : 'ws');
      final socket = connectBridgeSocket(wsUri, cookie: _cookie);
      _socket = socket;
      await socket.ready;
      socket.stream.listen(_onMessage, onDone: _onDone, onError: _onError);
      final hello = await _firstHello();
      connectionId =
          (hello['default_connection_id'] as String?) ?? connectionId;
      _setState(BridgeState.ready);
    } catch (e) {
      // cookie can outlive a bridge restart; drop it so the next attempt logs in again
      _cookie = null;
      _setState(BridgeState.failed, e.toString());
      rethrow;
    }
  }

  Completer<Map<String, dynamic>>? _helloCompleter;

  Future<Map<String, dynamic>> _firstHello() {
    final c = Completer<Map<String, dynamic>>();
    _helloCompleter = c;
    return c.future.timeout(const Duration(seconds: 12));
  }

  void _onMessage(dynamic raw) {
    final msg = jsonDecode(raw as String) as Map<String, dynamic>;
    if (msg['hello'] == true) {
      _helloCompleter?.complete(msg);
      _helloCompleter = null;
      return;
    }
    final terminal = msg['terminal'];
    if (terminal is Map<String, dynamic>) {
      final b64 = terminal['bytes'] as String?;
      if (b64 != null && b64.isNotEmpty) {
        _frames.add(
          TerminalFrame(
            terminalId: terminal['terminal_id'] as String,
            width: (terminal['width'] as num).toInt(),
            height: (terminal['height'] as num).toInt(),
            split: terminal['split'] == true,
            full: terminal['full'] == true,
            bytes: utf8.decode(base64Decode(b64), allowMalformed: true),
          ),
        );
      }
      return;
    }
    // Scout pushes bare `assistant`/`assistant_notification` keys, no `event` envelope
    if (msg['assistant'] is Map) {
      _events.add({'event': 'assistant', 'data': msg['assistant']});
      return;
    }
    if (msg['assistant_notification'] is Map) {
      final data = (msg['assistant_notification'] as Map)
          .cast<String, dynamic>();
      _events.add({'event': 'assistant_notification', 'data': data});
      final title = data['title'] as String?;
      if (title != null) {
        _notices.add(
          TaskNotice(kind: 'scout', title: title, body: str(data['body'])),
        );
      }
      return;
    }
    final event = msg['event'];
    if (event is String) {
      final data = msg['data'];
      _events.add({'event': event, 'data': data});
      if (event == 'task_notification' && data is Map) {
        final j = data.cast<String, dynamic>();
        _notices.add(
          TaskNotice(
            kind: (j['kind'] as String?) ?? 'completed',
            title: str(j['title']),
            body: str(j['body']),
            agent: j['agent'] as String?,
            workspaceId: j['workspace_id'] as String?,
            tabId: j['tab_id'] as String?,
            paneId: j['pane_id'] as String?,
          ),
        );
      }
      return;
    }
    final id = msg['id'];
    if (id is String) {
      final completer = _pending.remove(id);
      if (completer == null) return;
      final error = msg['error'];
      if (error != null) {
        completer.completeError(BridgeError(_errorText(error)));
      } else {
        completer.complete(
          (msg['result'] as Map?)?.cast<String, dynamic>() ?? const {},
        );
      }
    }
  }

  static String _errorText(Object error) {
    if (error is Map && error['message'] is String) {
      return error['message'] as String;
    }
    return error.toString();
  }

  void _onDone() {
    if (_current != BridgeState.failed) {
      _setState(BridgeState.idle, 'Connection closed');
    }
    _failPending(BridgeError('Connection closed', transport: true));
  }

  void _onError(Object error) {
    _setState(BridgeState.failed, error.toString());
    _failPending(BridgeError(error.toString(), transport: true));
  }

  void _failPending(Object error) {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(error);
    }
    _pending.clear();
  }

  /// the bridge rejects a connection id on bridge-global methods
  bool _isBridgeGlobal(String method) =>
      method.startsWith('bridge.') || method.startsWith('connections.');

  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
    Duration timeout = const Duration(seconds: 20),
  ]) async {
    try {
      return await _callOnce(method, params, timeout);
    } on BridgeError catch (e) {
      // Android Chrome kills backgrounded sockets silently; redial once on
      // transport errors only, never on RPC errors
      if (!e.transport || _redial == null) rethrow;
      final redial = _redial!;
      _redial = null;
      await redial();
      return _callOnce(method, params, timeout);
    }
  }

  Future<void> Function()? _redial;
  set redial(Future<void> Function()? fn) => _redial = fn;

  Future<Map<String, dynamic>> _callOnce(
    String method,
    Map<String, dynamic> params,
    Duration timeout,
  ) {
    final socket = _socket;
    if (socket == null) throw BridgeError('Not connected', transport: true);
    final id = 'd${++_seq}';
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    socket.sink.add(
      jsonEncode({
        'id': id,
        'method': method,
        'params': params,
        if (!_isBridgeGlobal(method)) 'connection_id': connectionId,
      }),
    );
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        throw BridgeError('$method timed out', transport: true);
      },
    );
  }

  Future<List<WorkspaceInfo>> workspaces() async {
    final r = await call('workspace.list');
    return maps(r['workspaces']).map(WorkspaceInfo.fromJson).toList();
  }

  Future<List<TabInfo>> tabs(String workspaceId) async {
    final r = await call('tab.list', {'workspace_id': workspaceId});
    return maps(r['tabs']).map(TabInfo.fromJson).toList();
  }

  Future<List<PaneInfo>> panes(String workspaceId) async {
    final r = await call('pane.list', {'workspace_id': workspaceId});
    return maps(r['panes']).map(PaneInfo.fromJson).toList();
  }

  Future<({int offset, bool split, int cols, int rows})> attach(
    String terminalId,
    int cols,
    int rows,
  ) async {
    final r = await call('terminal.attach', {
      'terminal_id': terminalId,
      'cols': cols,
      'rows': rows,
    });
    return (
      offset: integer(r['offset']) ?? 0,
      split: r['split'] == true,
      cols: integer(r['cols']) ?? 0,
      rows: integer(r['rows']) ?? 0,
    );
  }

  Future<void> detach(String terminalId) async {
    await call('terminal.detach', {'terminal_id': terminalId});
  }

  Future<void> input(String terminalId, String data) async {
    await call('terminal.input', {
      'terminal_id': terminalId,
      'data': base64Encode(utf8.encode(data)),
    });
  }

  Future<void> resize(String terminalId, int cols, int rows) async {
    await call('terminal.resize', {
      'terminal_id': terminalId,
      'cols': cols,
      'rows': rows,
    });
  }

  Future<int> scroll(String terminalId, int lines, {required bool up}) async {
    final r = await call('terminal.scroll', {
      'terminal_id': terminalId,
      'direction': up ? 'up' : 'down',
      'lines': lines.abs(),
      'source': 'wheel',
    });
    return integer(r['offset']) ?? 0;
  }

  Future<void> sendText(String paneId, String text) async {
    await call('pane.send_text', {'pane_id': paneId, 'text': text});
  }

  Future<List<String>> sessionReasoning(
    String paneId,
    String workspaceId,
    String tabId,
  ) async {
    final r = await call('agent_session.get', {
      'pane_id': paneId,
      'workspace_id': workspaceId,
      'tab_id': tabId,
      'include_trajectory': true,
    });
    final trajectory = r['trajectory'];
    final steps = trajectory is Map ? trajectory['steps'] : null;
    if (steps is! List) return const [];
    final out = <String>[];
    for (final step in steps) {
      if (step is! Map) continue;
      final reasoning = (step['reasoning_content'] as String?)?.trim();
      final message = (step['message'] as String?)?.trim();
      if (reasoning == null || reasoning.isEmpty || reasoning == message) {
        continue;
      }
      out.add(reasoning);
    }
    return out;
  }

  Future<void> sendPrompt(String paneId, String text) async {
    await call('pane.send_input', {
      'pane_id': paneId,
      'text': text,
      'keys': ['enter'],
    });
  }

  Future<void> sendKeys(String paneId, List<String> keys) async {
    await call('pane.send_keys', {'pane_id': paneId, 'keys': keys});
  }

  Future<void> closePane(String paneId) async {
    await call('pane.close', {'pane_id': paneId});
  }

  Future<void> renamePane(String paneId, String label) async {
    await call('pane.rename', {'pane_id': paneId, 'label': label});
  }

  Future<void> focusPane(String paneId) async {
    await call('pane.focus', {'pane_id': paneId});
  }

  Future<PaneInfo> splitPane(
    String workspaceId,
    String paneId,
    String direction, {
    String? cwd,
  }) async {
    final r = await call('pane.split', {
      'workspace_id': workspaceId,
      'pane_id': paneId,
      'direction': direction,
      if (cwd != null && cwd.isNotEmpty) 'cwd': cwd,
    });
    return PaneInfo.fromJson(r['pane'] as Map<String, dynamic>);
  }

  Future<void> zoomPane(String paneId, {String mode = 'toggle'}) async {
    await call('pane.zoom', {'pane_id': paneId, 'mode': mode});
  }

  Future<void> createTab(
    String workspaceId, {
    String? cwd,
    String? label,
  }) async {
    await call('tab.create', {
      'workspace_id': workspaceId,
      if (cwd != null && cwd.isNotEmpty) 'cwd': cwd,
      if (label != null && label.isNotEmpty) 'label': label,
      'focus': true,
    });
  }

  Future<void> renameTab(String tabId, String label) async {
    await call('tab.rename', {'tab_id': tabId, 'label': label});
  }

  Future<void> closeTab(String tabId) async {
    await call('tab.close', {'tab_id': tabId});
  }

  Future<void> createWorkspace({String? cwd}) async {
    await call('workspace.create', {
      if (cwd != null && cwd.isNotEmpty) 'cwd': cwd,
      'focus': true,
    });
  }

  Future<void> renameWorkspace(String workspaceId, String label) async {
    await call('workspace.rename', {
      'workspace_id': workspaceId,
      'label': label,
    });
  }

  Future<Map<String, dynamic>> info() async {
    final res = await http.get(bridgeUri(baseUrl, 'api/info'));
    if (res.statusCode != 200) {
      throw BridgeError('The bridge could not answer (${res.statusCode}).');
    }
    final decoded = jsonDecode(res.body);
    if (decoded is! Map<String, dynamic>) {
      throw BridgeError('The bridge sent something unreadable.');
    }
    return decoded;
  }

  Future<StagedFile> upload(String filename, List<int> bytes) async {
    final uri = bridgeUri(
      baseUrl,
      'api/terminal-upload',
      query: {'filename': filename},
    );
    final res = await http.post(
      uri,
      headers: {..._authHeaders, 'content-type': 'application/octet-stream'},
      body: bytes,
    );
    if (res.statusCode != 200) {
      throw BridgeError('Could not attach the file (${res.statusCode}).');
    }
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    final path = str(j['path']);
    if (path.isEmpty) {
      throw BridgeError('The file went through with no location.');
    }
    return StagedFile(path: path, name: filename, size: bytes.length);
  }

  Future<void> paste(String terminalId, String text) async {
    await input(terminalId, '\x1b[200~$text\x1b[201~');
  }

  Future<Map<String, dynamic>> listFiles(
    String workspaceId, {
    String path = '',
    bool showHidden = false,
    bool filesystem = false,
  }) => call('file.list', {
    'workspace_id': workspaceId,
    if (path.isNotEmpty) 'path': path,
    if (showHidden) 'show_hidden': true,
    if (filesystem) 'scope': 'filesystem',
  });

  Future<Map<String, dynamic>> historyEntry({
    required String entryId,
    required String paneId,
    required String terminalId,
  }) => call('agent_history.entry', {
    'entry_id': entryId,
    'pane_id': paneId,
    'terminal_id': terminalId,
  });

  Future<Map<String, dynamic>> readFile(String workspaceId, String path) =>
      call('file.read', {'workspace_id': workspaceId, 'path': path});

  Future<void> writeFile(String workspaceId, String path, String text) async {
    final slash = path.lastIndexOf('/');
    final directory = slash > 0 ? path.substring(0, slash) : '';
    final filename = slash >= 0 ? path.substring(slash + 1) : path;
    final uri = bridgeUri(
      baseUrl,
      'api/file/upload',
      query: {
        'workspace_id': workspaceId,
        'directory': directory,
        'filename': filename,
      },
    );
    final res = await http.post(
      uri,
      headers: {..._authHeaders, 'content-type': 'application/octet-stream'},
      body: utf8.encode(text),
    );
    if (res.statusCode != 200) {
      throw BridgeError('Could not save the file (${res.statusCode}).');
    }
  }

  Future<void> createDirectory(
    String workspaceId,
    String directory,
    String name,
  ) => call('file.mkdir', {
    'workspace_id': workspaceId,
    'directory': directory,
    'name': name,
  });

  Future<void> moveFile(String workspaceId, String path, String directory) =>
      call('file.move', {
        'workspace_id': workspaceId,
        'path': path,
        'directory': directory,
      });

  Future<void> deleteFile(String workspaceId, String path) async {
    final uri = bridgeUri(
      baseUrl,
      'api/file/delete',
      query: {'workspace_id': workspaceId, 'path': path},
    );
    final res = await http.post(uri, headers: _authHeaders);
    if (res.statusCode != 200) {
      throw BridgeError('Could not delete it (${res.statusCode}).');
    }
  }

  Future<void> dispose() async {
    await _socket?.sink.close();
    _socket = null;
    await _frames.close();
    await _events.close();
    await _state.close();
    await _notices.close();
  }
}

class TaskNotice {
  TaskNotice({
    required this.kind,
    required this.title,
    required this.body,
    this.agent,
    this.workspaceId,
    this.tabId,
    this.paneId,
  });

  final String kind;
  final String title;
  final String body;
  final String? agent;
  final String? workspaceId;
  final String? tabId;
  final String? paneId;
}

class StagedFile {
  StagedFile({required this.path, required this.name, required this.size});

  final String path;
  final String name;
  final int size;
}

Uri bridgeUri(Uri base, String route, {Map<String, String>? query}) {
  final prefix = base.path.endsWith('/')
      ? base.path.substring(0, base.path.length - 1)
      : base.path;
  return base.replace(path: '$prefix/$route', queryParameters: query);
}

class BridgeError implements Exception {
  BridgeError(this.message, {this.transport = false});
  final String message;

  final bool transport;
  @override
  String toString() => message;
}
