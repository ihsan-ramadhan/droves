import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../bridge/bridge.dart';
import '../model/app_state.dart';
import '../theme/tokens.dart';
import 'connect_screen.dart';
import 'workspace_screen.dart';
import 'widgets.dart';

/// what is running, and which of it is waiting on you
class InboxScreen extends StatefulWidget {
  const InboxScreen({super.key});

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> with BridgeAccess {
  List<WorkspaceInfo> _workspaces = const [];
  bool _loading = false;
  String? _error;
  Timer? _poll;

  @override
  void onBridgeReady() {
    _load();
    _poll ??= Timer.periodic(
      const Duration(seconds: 5),
      (_) => _load(silent: true),
    );
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    final live = app.bridge;
    if (live == null || live.state != BridgeState.ready) {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
      return;
    }
    if (!silent && mounted) setState(() => _loading = true);
    try {
      final next = await live.workspaces();
      if (!mounted) return;
      setState(() {
        _workspaces = next;
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

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    if (state.bridge == null || state.state == BridgeState.failed) {
      return DrovesScaffold(
        title: 'Droves',
        subtitle: const LedgerLabel('not connected'),
        child: Center(
          child: StateMessage(
            headline: state.error?.isNotEmpty == true
                ? 'Connection failed'
                : 'No bridge connected',
            body: state.error?.isNotEmpty == true
                ? state.error!
                : 'Connect to the machine that runs your agents.',
            icon: Icons.cable_outlined,
            action: FilledButton(
              onPressed: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const ConnectScreen())),
              child: Text(
                'Add bridge',
                style: Theme.of(context).textTheme.labelLarge
                    ?.copyWith(color: Theme.of(context).colorScheme.onPrimary),
              ),
            ),
          ),
        ),
      );
    }

    final waiting = _workspaces.where((w) => w.agentStatus == 'blocked').length;
    final working = _workspaces.where((w) => w.agentStatus == 'working').length;
    final status = connectionSubtitle(context, _error);
    final connectionLabel = status.isEmpty ? null : status;

    return DrovesScaffold(
      title: 'Inbox',
      subtitle: LedgerLabel(
        connectionLabel ??
            (_loading
                ? 'reading machines'
                : '${_workspaces.length} spaces · $working working · $waiting waiting'),
      ),
      actions: [RefreshButton(busy: _loading, onPressed: () => _load())],
      child: RefreshIndicator(
        color: context.colors.ink,
        onRefresh: () => _load(),
        child: _buildBody(context),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final c = context.colors;
    final live = app.bridge;
    final connected = live != null && live.state == BridgeState.ready;
    final state = ScreenState(
      loading: _loading && _workspaces.isEmpty,
      error: _error,
      connected: connected,
      empty: _workspaces.isEmpty,
      subject: 'workspaces',
      emptyHeadline: 'No workspaces open',
      emptyBody: 'Start a pane on the machine, then pull to refresh.',
      onRetry: connectionRetry(context, () => _load()),
      rows: 6,
      emptyIcon: Icons.inbox_outlined,
    );
    if (_loading && _workspaces.isEmpty ||
        !connected ||
        _error != null ||
        _workspaces.isEmpty) {
      return ListView(children: [state]);
    }
    return ListView.separated(
      itemCount: _workspaces.length,
      separatorBuilder: (_, _) => Divider(color: c.rule, height: 1),
      itemBuilder: (_, i) => _WorkspaceRow(
        workspace: _workspaces[i],
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => WorkspaceScreen(workspace: _workspaces[i]),
          ),
        ),
      ),
    );
  }
}

class _WorkspaceRow extends StatelessWidget {
  const _WorkspaceRow({required this.workspace, required this.onTap});

  final WorkspaceInfo workspace;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final waiting = workspace.agentStatus == 'blocked';
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: Space.md,
        vertical: 6,
      ),
      title: Row(
        children: [
          SizedBox(
            width: 26,
            child: Text(
              workspace.number.toString().padLeft(2, '0'),
              style: monoStyle(context, size: 11, color: c.muted),
            ),
          ),
          TallyRail(workspaces: [workspace], max: 1),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  workspace.label.isEmpty
                      ? workspace.workspaceId
                      : workspace.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: nameStyle(
                    context,
                    size: 16.5,
                    weight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${workspace.tabCount} tab${workspace.tabCount == 1 ? '' : 's'} · ${workspace.paneCount} pane${workspace.paneCount == 1 ? '' : 's'}',
                  style: monoStyle(context, size: 11, color: c.muted),
                ),
              ],
            ),
          ),
          const SizedBox(width: Space.sm),
          StatusWord(workspace.agentStatus),
          if (waiting) ...[
            const SizedBox(width: Space.sm),
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(Radii.xs),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
