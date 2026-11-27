import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../bridge/bridge.dart';
import '../model/app_state.dart';
import '../theme/tokens.dart';
import 'common/bridge_access.dart';
import 'common/scaffold.dart';
import 'common/state_message.dart';
import 'common/status_group.dart';
import 'screen_loader.dart';
import 'workspace_screen.dart';

/// what is running, and which of it is waiting on you
class InboxScreen extends StatefulWidget {
  const InboxScreen({super.key});

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen>
    with BridgeAccess, ScreenLoader {
  List<WorkspaceInfo> _workspaces = const [];
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
    if (!app.connected) return idle();
    await load(() async {
      final next = await bridge.workspaces();
      if (!mounted) return;
      setState(() => _workspaces = next);
    }, silent: silent);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    // one layout for every non-ready state: flipping between the centred
    // message and the list body on a retry read as a jump upward
    if (state.bridge == null || state.state != BridgeState.ready) {
      final status = connectionSubtitle(context, error);
      return DrovesScaffold(
        title: 'Droves',
        subtitle: LedgerLabel(status.isEmpty ? 'not connected' : status),
        child: Center(child: BridgeDownState(error: error)),
      );
    }

    final waiting = _workspaces.where((w) => w.agentStatus == 'blocked').length;
    final working = _workspaces.where((w) => w.agentStatus == 'working').length;
    final status = connectionSubtitle(context, error);
    final connectionLabel = status.isEmpty ? null : status;

    return DrovesScaffold(
      title: 'Inbox',
      subtitle: LedgerLabel(
        connectionLabel ??
            (loading
                ? 'reading machines'
                : '${_workspaces.length} spaces · $working working · $waiting waiting'),
      ),
      actions: [RefreshButton(busy: loading, onPressed: () => _load())],
      child: RefreshIndicator(
        color: context.colors.ink,
        onRefresh: () => _load(),
        child: _buildBody(context),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final c = context.colors;
    final connected = app.connected;
    final state = ScreenState(
      loading: loading && _workspaces.isEmpty,
      error: error,
      connected: connected,
      empty: _workspaces.isEmpty,
      subject: 'workspaces',
      emptyHeadline: 'No workspaces open',
      emptyBody: 'Start a pane on the machine, then pull to refresh.',
      onRetry: connectionRetry(context, () => _load()),
      rows: 6,
      emptyIcon: Icons.inbox_outlined,
    );
    if (loading && _workspaces.isEmpty ||
        !connected ||
        error != null ||
        _workspaces.isEmpty) {
      return ListView(children: [state]);
    }
    final sections = statusSections(_workspaces, (w) => w.agentStatus);
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        for (final section in sections) ...[
          StatusSectionHeader(
            group: section.group,
            count: section.items.length,
          ),
          for (var i = 0; i < section.items.length; i++) ...[
            if (i > 0) Divider(color: c.rule, height: 1),
            _WorkspaceRow(
              workspace: section.items[i],
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => WorkspaceScreen(workspace: section.items[i]),
                ),
              ),
            ),
          ],
        ],
      ],
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
