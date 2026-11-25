import 'package:material_ui/material_ui.dart';

import '../bridge/bridge.dart';

import '../model/app_state.dart';
import '../theme/tokens.dart';
import 'connect_screen.dart';
import 'widgets.dart';

/// one host the bridge can reach; a bridge often fronts several (local socket, SSH, another room)
class ConnectionInfo {
  ConnectionInfo({
    required this.id,
    required this.label,
    required this.state,
    required this.type,
    required this.isDefault,
    required this.readOnly,
    this.controlSocket,
  });

  final String id;
  final String label;
  final String state;
  final String type;
  final bool isDefault;
  final bool readOnly;
  final String? controlSocket;

  factory ConnectionInfo.fromJson(Map<String, dynamic> j) => ConnectionInfo(
    id: (j['id'] as String?) ?? '',
    label: (j['label'] as String?) ?? '',
    state: (j['state'] as String?) ?? 'unknown',
    type: (j['type'] as String?) ?? 'local',
    isDefault: j['is_default'] == true,
    readOnly: j['read_only'] == true,
    controlSocket: j['control_socket_path'] as String?,
  );
}

/// top group: where Droves dials; bottom group: which host inside that bridge
class ConnectionsScreen extends StatefulWidget {
  const ConnectionsScreen({super.key});

  @override
  State<ConnectionsScreen> createState() => _ConnectionsScreenState();
}

class _ConnectionsScreenState extends State<ConnectionsScreen>
    with BridgeAccess {
  List<ConnectionInfo> _connections = const [];
  bool _loading = true;
  String? _error;

  @override
  void onBridgeReady() => _load();

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final r = await bridge.call('connections.list');
      if (!mounted) return;
      setState(() {
        _connections = ((r['connections'] as List?) ?? const [])
            .cast<Map<String, dynamic>>()
            .map(ConnectionInfo.fromJson)
            .toList();
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _use(ConnectionInfo c) async {
    final messenger = ScaffoldMessenger.of(context);
    final style = monoStyle(context, size: 12);
    try {
      await bridge.call('connections.connect', {
        'connection_id': c.id,
        'promote_to_default': true,
      });
      bridge.connectionId = c.id;
      messenger.showSnackBar(
        SnackBar(content: Text('Now reading ${c.label}', style: style)),
      );
      await _load();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e.toString(), style: style)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final state = AppScope.of(context);
    final live = app.bridge;
    final connected = live != null && live.state == BridgeState.ready;
    final status = connectionSubtitle(context, _error);
    return DrovesScaffold(
      title: 'Machines',
      subtitle: LedgerLabel(
        status.isNotEmpty
            ? status
            : _loading
            ? 'reading connections'
            : '${_connections.length} inside this bridge',
      ),
      leading: IconButton(
        icon: const Icon(Icons.arrow_back, size: 20),
        color: c.ink,
        tooltip: 'Back',
        onPressed: () => Navigator.of(context).maybePop(),
      ),
      actions: [RefreshButton(busy: _loading, onPressed: _load)],
      child: ListView(
        children: [
          _GroupLabel('Bridges'),
          for (var i = 0; i < state.endpoints.length; i++)
            _EndpointRow(
              endpoint: state.endpoints[i],
              active: i == state.activeIndex && state.bridge != null,
              onUse: i == state.activeIndex
                  ? null
                  : () => state.useEndpoint(i).catchError((_) {}),
              onForget: () => state.forgetEndpoint(i),
            ),
          ListTile(
            leading: Icon(Icons.add, size: 18, color: c.ink),
            title: Text(
              'Add another bridge',
              style: monoStyle(context, size: 12),
            ),
            subtitle: Text(
              'Reach another machine through this bridge',
              style: monoStyle(context, size: 10.5, color: c.muted),
            ),
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const ConnectScreen())),
          ),
          Divider(color: c.rule, height: 1),
          _GroupLabel('Hosts in this bridge'),
          if (_loading ||
              _error != null ||
              !connected ||
              _connections.isEmpty)
            ScreenState(
              loading: _loading,
              error: _error,
              connected: connected,
              empty: _connections.isEmpty,
              subject: 'hosts',
              emptyHeadline: 'No hosts inside this bridge',
              emptyBody:
                  'Add a host on the machine that runs the bridge, then refresh.',
              onRetry: connectionRetry(context, _load),
              rows: 2,
              rowHeight: 56,
              emptyIcon: Icons.computer_outlined,
            )
          else
            for (final conn in _connections)
              _HostRow(conn: conn, bridge: bridge, onUse: () => _use(conn)),
          const SizedBox(height: Space.xl),
        ],
      ),
    );
  }
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(
        Space.md,
        Space.lg,
        Space.md,
        Space.xs,
      ),
      child: LedgerLabel(text),
    );
  }
}

class _EndpointRow extends StatelessWidget {
  const _EndpointRow({
    required this.endpoint,
    required this.active,
    required this.onUse,
    required this.onForget,
  });

  final Endpoint endpoint;
  final bool active;
  final VoidCallback? onUse;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ListTile(
      title: Row(
        children: [
          Text(endpoint.displayLabel, style: nameStyle(context, size: 15)),
          if (active) ...[
            const SizedBox(width: Space.sm),
            LedgerLabel('live', color: c.accent),
          ],
        ],
      ),
      subtitle: Text(
        endpoint.url,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: monoStyle(context, size: 10.5, color: c.muted),
      ),
      trailing: IconButton(
        icon: const Icon(Icons.close, size: 16),
        color: c.muted,
        tooltip: 'Forget this bridge',
        onPressed: onForget,
      ),
      onTap: onUse,
    );
  }
}

class _HostRow extends StatelessWidget {
  const _HostRow({
    required this.conn,
    required this.bridge,
    required this.onUse,
  });

  final ConnectionInfo conn;
  final dynamic bridge;
  final VoidCallback onUse;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final active = conn.id == bridge.connectionId;
    return ListTile(
      title: Row(
        children: [
          Text(
            conn.label.isEmpty ? conn.id : conn.label,
            style: nameStyle(context, size: 15),
          ),
          if (conn.isDefault) ...[
            const SizedBox(width: Space.sm),
            LedgerLabel('default', color: c.accent),
          ],
        ],
      ),
      subtitle: Text(
        '${conn.type} · ${conn.state}${conn.readOnly ? ' · read-only' : ''}',
        style: monoStyle(context, size: 10.5, color: c.muted),
      ),
      trailing: active
          ? Icon(Icons.check, size: 16, color: c.ink)
          : Text('Use', style: monoStyle(context, size: 11, color: c.ink)),
      onTap: active ? null : onUse,
    );
  }
}
