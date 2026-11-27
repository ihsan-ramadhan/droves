import 'package:material_ui/material_ui.dart';

import '../bridge/bridge.dart';
import '../theme/tokens.dart';
import 'chat_screen.dart';
import 'common/bridge_access.dart';
import 'common/scaffold.dart';
import 'common/state_message.dart';
import 'dialogs.dart';
import 'files_screen.dart';
import 'git_screen.dart';
import 'screen_loader.dart';
import 'search_screen.dart';
import 'terminal_screen.dart';

/// tabs at the top, panes of the active tab as rows
class WorkspaceScreen extends StatefulWidget {
  const WorkspaceScreen({super.key, required this.workspace});

  final WorkspaceInfo workspace;

  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen>
    with BridgeAccess, ScreenLoader {
  List<TabInfo> _tabs = const [];
  List<PaneInfo> _panes = const [];
  String? _activeTab;

  @override
  void onBridgeReady() => _load();

  Future<void> _load() async {
    await load(() async {
      final tabs = await bridge.tabs(widget.workspace.workspaceId);
      final panes = await bridge.panes(widget.workspace.workspaceId);
      if (!mounted) return;
      setState(() {
        _tabs = tabs;
        _panes = panes;
        final current = _activeTab;
        if (current != null && tabs.any((t) => t.tabId == current)) {
          _activeTab = current;
        } else {
          final preferred = widget.workspace.activeTabId;
          _activeTab =
              (preferred != null &&
                  tabs.any((t) => t.tabId == preferred && t.paneCount > 0))
              ? preferred
              : tabs.where((t) => t.paneCount > 0).firstOrNull?.tabId ??
                    (tabs.isEmpty ? null : tabs.first.tabId);
        }
      });
    });
  }

  Future<void> _newTab() async {
    final label = await promptText(
      context,
      title: 'New tab',
      hint: 'Label (optional)',
      confirmLabel: 'Save',
    );
    if (label == null) return;
    try {
      await bridge.createTab(
        widget.workspace.workspaceId,
        cwd: widget.workspace.cwd,
        label: label.isEmpty ? null : label,
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      showError(context, e);
    }
  }

  Future<void> _paneActions(PaneInfo pane) async {
    final c = context.colors;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.md,
                Space.md,
                Space.md,
                Space.sm,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: LedgerLabel(pane.titleOrCwd),
              ),
            ),
            for (final item in [
              ('Rename pane', 'rename'),
              ('Bring to front', 'focus'),
              ('Split right', 'split-right'),
              ('Zoom pane', 'zoom'),
              ('Close pane', 'close'),
            ])
              ListTile(
                title: Text(
                  item.$1,
                  style: monoStyle(
                    context,
                    size: 12.5,
                    color: item.$2 == 'close' ? c.error : c.ink,
                  ),
                ),
                onTap: () => Navigator.of(sheet).pop(item.$2),
              ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    try {
      switch (action) {
        case 'rename':
          final label = await promptText(
            context,
            title: 'Rename pane',
            hint: 'Label',
            confirmLabel: 'Save',
          );
          if (label == null || !mounted) return;
          await bridge.renamePane(pane.paneId, label);
        case 'focus':
          await bridge.focusPane(pane.paneId);
        case 'split-right':
          final created = await bridge.splitPane(
            widget.workspace.workspaceId,
            pane.paneId,
            'right',
            cwd: pane.cwd,
          );
          if (mounted) setState(() => _activeTab = created.tabId);
        case 'zoom':
          await bridge.zoomPane(pane.paneId);
        case 'close':
          final ok = await confirmDialog(
            context,
            title: 'Close this pane?',
            body: 'Running programs in it will stop.',
            cancelLabel: 'Keep',
            confirmLabel: 'Close',
            destructive: true,
          );
          if (!ok || !mounted) return;
          await bridge.closePane(pane.paneId);
      }
      await _load();
    } catch (e) {
      if (!mounted) return;
      showError(context, e);
    }
  }

  Future<void> _tabActions(TabInfo tab) async {
    final c = context.colors;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.md,
                Space.md,
                Space.md,
                Space.sm,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: LedgerLabel(
                  tab.label.isEmpty ? 'Tab ${tab.number}' : tab.label,
                ),
              ),
            ),
            for (final item in [
              ('Focus tab', 'focus'),
              ('Rename tab', 'rename'),
              ('Close tab', 'close'),
            ])
              ListTile(
                title: Text(
                  item.$1,
                  style: monoStyle(
                    context,
                    size: 12.5,
                    color: item.$2 == 'close' ? c.error : c.ink,
                  ),
                ),
                onTap: () => Navigator.of(sheet).pop(item.$2),
              ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    try {
      switch (action) {
        case 'focus':
          setState(() => _activeTab = tab.tabId);
          await bridge.call('tab.focus', {'tab_id': tab.tabId});
        case 'rename':
          final label = await promptText(
            context,
            title: 'Rename tab',
            hint: 'Label',
            confirmLabel: 'Save',
          );
          if (label == null || !mounted) return;
          await bridge.renameTab(tab.tabId, label);
        case 'close':
          final ok = await confirmDialog(
            context,
            title: 'Close this tab?',
            body: 'All panes in it will stop.',
            cancelLabel: 'Keep',
            confirmLabel: 'Close',
            destructive: true,
          );
          if (!ok || !mounted) return;
          await bridge.closeTab(tab.tabId);
      }
      await _load();
    } catch (e) {
      if (!mounted) return;
      showError(context, e);
    }
  }

  String _paneCount() {
    final n = _panes.length;
    return '$n pane${n == 1 ? '' : 's'}';
  }

  String _status() {
    final focused = _visiblePanes.where((p) => p.focused);
    final source = focused.isNotEmpty
        ? focused.first
        : _visiblePanes.firstOrNull;
    if (source == null) return widget.workspace.agentStatus;
    return source.agentStatus;
  }

  List<PaneInfo> get _visiblePanes => _activeTab == null
      ? _panes
      : _panes.where((p) => p.tabId == _activeTab).toList();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final connected = app.connected;
    final status = connectionSubtitle(context, error);
    return DrovesScaffold(
      title: widget.workspace.label.isEmpty
          ? widget.workspace.workspaceId
          : widget.workspace.label,
      subtitle: LedgerLabel(
        status.isNotEmpty ? status : '${_paneCount()} · ${_status()}',
      ),
      leading: IconButton(
        icon: const Icon(Icons.arrow_back, size: 20),
        color: c.ink,
        tooltip: 'Back to inbox',
        onPressed: () => Navigator.of(context).maybePop(),
      ),
      actions: [
        if (connected) ...[
          RefreshButton(busy: loading, onPressed: _load),
          IconButton(
            icon: const Icon(Icons.add, size: 20),
            color: c.ink,
            tooltip: 'New tab',
            onPressed: _newTab,
          ),
          IconButton(
            icon: const Icon(Icons.search, size: 20),
            color: c.ink,
            tooltip: 'Search this workspace',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SearchScreen(
                  workspace: widget.workspace.workspaceId,
                  label: widget.workspace.label,
                ),
              ),
            ),
          ),
        ],
      ],
      child: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final c = context.colors;
    final connected = app.connected;
    final state = ScreenState(
      loading: loading && _panes.isEmpty,
      error: error,
      connected: connected,
      empty: _panes.isEmpty,
      subject: 'workspace',
      emptyHeadline: 'No panes in this workspace',
      emptyBody: 'Create a tab or pane on the machine, then refresh.',
      onRetry: connectionRetry(context, _load),
      rows: 3,
      rowHeight: 120,
      emptyIcon: Icons.terminal,
    );
    if (loading || !connected || error != null || _panes.isEmpty) {
      return state;
    }
    return Column(
      children: [
        if (_tabs.length > 1)
          SizedBox(
            height: 44,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Space.md),
              itemCount: _tabs.length,
              separatorBuilder: (_, _) => const SizedBox(width: Space.sm),
              itemBuilder: (_, i) {
                final tab = _tabs[i];
                final active = tab.tabId == _activeTab;
                return Center(
                  child: InkWell(
                    onTap: () => setState(() => _activeTab = tab.tabId),
                    onLongPress: () => _tabActions(tab),
                    borderRadius: BorderRadius.circular(Radii.lg),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: Space.md,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: active
                            ? Theme.of(context).colorScheme.primaryContainer
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(Radii.lg),
                      ),
                      child: Text(
                        tab.label.isEmpty ? 'Tab ${tab.number}' : tab.label,
                        style: monoStyle(
                          context,
                          size: 11,
                          color: active
                              ? Theme.of(context).colorScheme.onPrimaryContainer
                              : c.ink,
                          weight: active ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        if (_tabs.length > 1) Container(height: 1, color: c.rule),
        _InspectorBar(workspace: widget.workspace),
        Expanded(
          child: ListView.separated(
            itemCount: _visiblePanes.length,
            separatorBuilder: (_, _) => Divider(color: c.rule, height: 1),
            itemBuilder: (_, i) => _PaneRow(
              pane: _visiblePanes[i],
              workspaceLabel: widget.workspace.label,
              onLongPress: () => _paneActions(_visiblePanes[i]),
            ),
          ),
        ),
      ],
    );
  }
}

class _PaneRow extends StatelessWidget {
  const _PaneRow({
    required this.pane,
    required this.workspaceLabel,
    required this.onLongPress,
  });

  final PaneInfo pane;
  final String workspaceLabel;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final agent = pane.agent;
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) =>
              TerminalScreen(pane: pane, workspaceLabel: workspaceLabel),
        ),
      ),
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (agent != null && agent.isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      border: Border.all(color: c.rule),
                      borderRadius: BorderRadius.circular(2),
                    ),
                    child: Text(
                      agent,
                      style: monoStyle(context, size: 10, color: c.muted),
                    ),
                  ),
                  const SizedBox(width: Space.sm),
                ],
                Expanded(
                  child: Text(
                    pane.titleOrCwd,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: nameStyle(context, size: 15),
                  ),
                ),
                const SizedBox(width: Space.sm),
                StatusWord(pane.agentStatus),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              pane.cwd ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: monoStyle(context, size: 10.5, color: c.muted),
            ),
            if (agent != null && agent.isNotEmpty) ...[
              const SizedBox(height: Space.sm),
              Row(
                children: [
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            ChatScreen(pane: pane, label: workspaceLabel),
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      side: BorderSide(color: c.rule),
                    ),
                    child: Text('Chat', style: monoStyle(context, size: 11)),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// three inspector entry points on a phone: changes, commits, files
class _InspectorBar extends StatelessWidget {
  const _InspectorBar({required this.workspace});

  final WorkspaceInfo workspace;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final items = [
      (
        'Changes',
        Icons.account_tree_outlined,
        () =>
            GitScreen(workspace: workspace.workspaceId, label: workspace.label),
      ),
      (
        'Commits',
        Icons.history,
        () => CommitsScreen(
          workspace: workspace.workspaceId,
          label: workspace.label,
        ),
      ),
      (
        'Files',
        Icons.folder_outlined,
        () => FilesScreen(
          workspace: workspace.workspaceId,
          label: workspace.label,
        ),
      ),
    ];
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.rule)),
      ),
      child: Row(
        children: [
          for (final item in items)
            Expanded(
              child: InkWell(
                onTap: () =>
                    Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => item.$3())),
                child: SizedBox(
                  height: 44,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(item.$2, size: 15, color: c.muted),
                      const SizedBox(width: 6),
                      Text(
                        item.$1,
                        style: monoStyle(context, size: 11, color: c.muted),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
