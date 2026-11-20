import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../bridge/bridge.dart';
import '../model/app_state.dart';
import '../model/keybar.dart';
import '../notifications.dart';
import '../platform_web_stub.dart'
    if (dart.library.js_interop) '../platform_web.dart'
    as platform;
import '../theme/tokens.dart';
import '../updates.dart';
import 'chat_screen.dart';
import 'connections_screen.dart';
import 'ranger_screen.dart';
import 'connect_screen.dart';
import 'key_bar.dart';
import 'widgets.dart';

/// all agent-attached panes across workspaces
class AgentsScreen extends StatefulWidget {
  const AgentsScreen({super.key});

  @override
  State<AgentsScreen> createState() => _AgentsScreenState();
}

class _AgentsScreenState extends State<AgentsScreen> with BridgeAccess {
  List<PaneInfo> _agents = const [];
  Map<String, String> _workspaceLabels = const {};
  bool _loading = false;
  String? _error;

  @override
  void onBridgeReady() => _load();

  Future<void> _load() async {
    final live = app.bridge;
    if (live == null) {
      // no bridge yet: keep the empty state, not a skeleton that never resolves
      if (mounted) setState(() => _loading = false);
      return;
    }
    setState(() => _loading = true);
    try {
      final r = await live.call('agent.list');
      final raw = ((r['agents'] as List?) ?? const [])
          .cast<Map<String, dynamic>>();
      final workspaces = await live.workspaces();
      if (!mounted) return;
      setState(() {
        _agents = raw.map(PaneInfo.fromJson).toList();
        _workspaceLabels = {
          for (final w in workspaces)
            w.workspaceId: w.label.isEmpty ? w.workspaceId : w.label,
        };
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
    final waiting = _agents.where((a) => a.agentStatus == 'blocked').length;
    return DrovesScaffold(
      title: 'Agents',
      subtitle: LedgerLabel(
        _loading
            ? 'reading agents'
            : '${_agents.length} running · $waiting waiting',
      ),
      actions: [RefreshButton(busy: _loading, onPressed: _load)],
      child: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final c = context.colors;
    if (_loading && _agents.isEmpty) {
      return const SkeletonRows(rows: 6, rowHeight: 60);
    }
    if (_error != null) {
      return StateMessage(
        headline: 'Could not list agents',
        body: _error!,
        icon: Icons.error_outline,
        action: OutlinedButton(
          onPressed: _load,
          child: Text('Try again', style: monoStyle(context, size: 12)),
        ),
      );
    }
    if (_agents.isEmpty) {
      return const StateMessage(
        headline: 'No agents running',
        body: 'Start an agent in a pane on the machine.',
        icon: Icons.smart_toy_outlined,
      );
    }
    final sorted = [..._agents]
      ..sort((a, b) {
        int rank(String s) => switch (s) {
          'blocked' => 0,
          'working' => 1,
          'done' => 2,
          _ => 3,
        };
        return rank(a.agentStatus).compareTo(rank(b.agentStatus));
      });
    return RefreshIndicator(
      color: c.ink,
      onRefresh: _load,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: sorted.length,
        separatorBuilder: (_, _) => Divider(color: c.rule, height: 1),
        itemBuilder: (_, i) {
          final a = sorted[i];
          final label = _workspaceLabels[a.workspaceId] ?? a.workspaceId;
          return InkWell(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ChatScreen(pane: a, label: label),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.md,
                vertical: 13,
              ),
              child: Row(
                children: [
                  TallyRail(
                    workspaces: [
                      WorkspaceInfo(
                        workspaceId: a.workspaceId,
                        label: label,
                        number: 0,
                        paneCount: 1,
                        tabCount: 1,
                        agentStatus: a.agentStatus,
                      ),
                    ],
                  ),
                  const SizedBox(width: Space.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              a.agent ?? 'agent',
                              style: nameStyle(
                                context,
                                size: 15,
                                weight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(width: Space.sm),
                            Text(
                              label,
                              style: monoStyle(
                                context,
                                size: 10.5,
                                color: c.muted,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          a.titleOrCwd,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: monoStyle(context, size: 10.5, color: c.muted),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: Space.sm),
                  StatusWord(a.agentStatus),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// connection and theme settings; everything else lives where it is used
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.onThemeChanged,
    required this.themeMode,
  });

  final ValueChanged<ThemeMode> onThemeChanged;
  final ThemeMode themeMode;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final c = context.colors;
    final bridge = state.bridge;
    return DrovesScaffold(
      title: 'Settings',
      subtitle: const LedgerLabel('connection and app preferences'),
      child: ListView(
        children: [
          ListTile(
            title: Text('Ranger', style: nameStyle(context, size: 15)),
            subtitle: Text(
              'Ask across workspaces with the bridge model',
              style: monoStyle(context, size: 11, color: c.muted),
            ),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const RangerScreen())),
          ),
          Divider(color: c.rule, height: 1),
          // a browser can only reach the bridge that served it, so there is no other machine to switch to
          if (!kIsWeb) ...[
            ListTile(
              title: Text('Machines', style: nameStyle(context, size: 15)),
              subtitle: Text(
                'Switch the bridge every screen reads',
                style: monoStyle(context, size: 11, color: c.muted),
              ),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ConnectionsScreen()),
              ),
            ),
            Divider(color: c.rule, height: 1),
          ],
          _Section('Bridge'),
          ListTile(
            title: Text('Endpoint', style: monoStyle(context, size: 12)),
            subtitle: Text(
              bridge == null ? 'Not connected' : state.baseUrl,
              style: monoStyle(context, size: 11, color: c.muted),
            ),
            trailing: Text(
              bridge?.state.name ?? BridgeState.idle.name,
              style: monoStyle(context, size: 10, color: c.muted),
            ),
          ),
          ListTile(
            title: Text('Reconnect', style: monoStyle(context, size: 12)),
            subtitle: Text(
              'Enter the bridge URL and token again',
              style: monoStyle(context, size: 11, color: c.muted),
            ),
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const ConnectScreen())),
          ),
          if (bridge != null)
            ListTile(
              title: Text(
                'Disconnect',
                style: monoStyle(context, size: 12, color: c.accent),
              ),
              subtitle: Text(
                'Stops the live connection; saved bridges stay',
                style: monoStyle(context, size: 11, color: c.muted),
              ),
              onTap: () => _confirmDisconnect(context, state),
            ),
          if (state.endpoints.length > 1) ...[
            _Section('Saved bridges'),
            for (var i = 0; i < state.endpoints.length; i++)
              ListTile(
                title: Text(
                  state.endpoints[i].displayLabel,
                  style: monoStyle(context, size: 12),
                ),
                subtitle: Text(
                  state.endpoints[i].url,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: monoStyle(context, size: 10.5, color: c.muted),
                ),
                trailing: i == state.activeIndex
                    ? Icon(Icons.check, size: 16, color: c.ink)
                    : Text(
                        'Use',
                        style: monoStyle(context, size: 11, color: c.ink),
                      ),
                onTap: i == state.activeIndex
                    ? null
                    : () => state.useEndpoint(i).catchError((_) {}),
              ),
          ],
          _Section('Appearance'),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Space.md,
              vertical: Space.sm,
            ),
            child: Row(
              children: [
                for (final mode in [
                  ThemeMode.light,
                  ThemeMode.dark,
                  ThemeMode.system,
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: Space.sm),
                    child: ChoiceChip(
                      // label colour must come from ThemeData: Material overrides inline style on selection
                      label: Text(switch (mode) {
                        ThemeMode.light => 'Paper',
                        ThemeMode.dark => 'Night',
                        _ => 'System',
                      }),
                      labelStyle: TextStyle(
                        fontFamily: 'PlexMono',
                        fontSize: 11,
                        color: themeMode == mode ? c.paper : c.ink,
                      ),
                      selected: themeMode == mode,
                      onSelected: (_) => onThemeChanged(mode),
                      showCheckmark: false,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(Radii.row),
                        side: BorderSide(
                          color: themeMode == mode ? c.ink : c.rule,
                        ),
                      ),
                      selectedColor: c.ink,
                      backgroundColor: Colors.transparent,
                    ),
                  ),
              ],
            ),
          ),
          _Section('Keyboard'),
          const _ShortcutSettings(),
          _Section('Notifications'),
          SwitchListTile(
            title: Text('Agent activity', style: monoStyle(context, size: 12)),
            subtitle: Text(
              'Finished and waiting agents, while Droves is in the background',
              style: monoStyle(context, size: 11, color: c.muted),
            ),
            value: state.notificationsEnabled,
            activeTrackColor: c.ink,
            onChanged: (value) async {
              if (value) {
                final granted = await NotificationService.instance
                    .requestPermission();
                if (!granted) {
                  await state.setNotificationsEnabled(false);
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        kIsWeb
                            ? 'Notifications are blocked in browser settings.'
                            : 'Notifications are blocked in system settings.',
                        style: monoStyle(context, size: 12),
                      ),
                    ),
                  );
                  return;
                }
              }
              await state.setNotificationsEnabled(value);
            },
          ),
          for (final item in [
            ('Finished tasks', state.notifyCompleted, state.setNotifyCompleted),
            ('Needs your input', state.notifyBlocked, state.setNotifyBlocked),
            ('Ranger runs', state.notifyRanger, state.setNotifyRanger),
          ])
            Padding(
              padding: const EdgeInsets.only(left: Space.md),
              child: SwitchListTile(
                dense: true,
                contentPadding: const EdgeInsets.only(
                  left: Space.sm,
                  right: Space.md,
                ),
                title: Text(item.$1, style: monoStyle(context, size: 12)),
                value: item.$2,
                activeTrackColor: c.ink,
                onChanged: state.notificationsEnabled
                    ? (v) => item.$3(v)
                    : null,
              ),
            ),
          _Section('Connection'),
          SwitchListTile(
            title: Text(
              'Reconnect automatically',
              style: monoStyle(context, size: 12),
            ),
            subtitle: Text(
              'Dial the saved bridge again when it drops or the app comes back',
              style: monoStyle(context, size: 11, color: c.muted),
            ),
            value: state.autoReconnect,
            activeTrackColor: c.ink,
            onChanged: (v) => state.setAutoReconnect(v),
          ),
          _Section('App'),
          ListTile(
            title: Text('Version', style: monoStyle(context, size: 12)),
            subtitle: Text(
              'Pre-release build',
              style: monoStyle(context, size: 11, color: c.muted),
            ),
            trailing: Text(
              state.currentVersion.isEmpty ? '…' : state.currentVersion,
              style: monoStyle(context, size: 11, color: c.muted),
            ),
          ),
          ListTile(
            title: Text(
              'Check for updates',
              style: monoStyle(context, size: 12),
            ),
            subtitle: Text(
              state.updateChecking
                  ? 'Checking…'
                  : state.update != null
                  ? 'Version ${state.update!.latest} is available'
                  : state.updateError ??
                        (state.lastUpdateCheck == null
                            ? 'Not checked yet'
                            : 'Up to date'),
              style: monoStyle(context, size: 11, color: c.muted),
            ),
            trailing: state.updateChecking
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  )
                : Icon(Icons.refresh, size: 16, color: c.muted),
            onTap: state.updateChecking
                ? null
                : () => state.checkForUpdates(silent: false),
          ),
          if (state.update != null)
            ListTile(
              title: Text(
                kIsWeb
                    ? 'Reload to update'
                    : Theme.of(context).platform == TargetPlatform.iOS
                    ? 'Update in SideStore'
                    : 'Install ${state.update!.latest}',
                style: monoStyle(context, size: 12, color: c.accent),
              ),
              subtitle: Text(
                Theme.of(context).platform == TargetPlatform.iOS && !kIsWeb
                    ? 'Open SideStore → My Apps and tap update on Droves.'
                    : state.update!.notes.isEmpty
                    ? 'A newer Droves build is ready.'
                    : state.update!.notes,
                style: monoStyle(context, size: 11, color: c.muted),
              ),
              trailing: Icon(
                Icons.download_outlined,
                size: 16,
                color: c.accent,
              ),
              onTap: () => _applyUpdate(context, state.update!),
            ),
          _Section('About'),
          ListTile(
            title: Text('Source code', style: monoStyle(context, size: 12)),
            subtitle: Text(
              'github.com/ihsan-ramadhan/droves',
              style: monoStyle(context, size: 10.5, color: c.muted),
            ),
            trailing: Icon(Icons.open_in_new, size: 16, color: c.muted),
            onTap: () => _openRepo(context),
          ),
          ListTile(
            title: Text('Licenses', style: monoStyle(context, size: 12)),
            subtitle: Text(
              'Apache-2.0, bundled fonts and package licenses',
              style: monoStyle(context, size: 11, color: c.muted),
            ),
            trailing: Icon(
              Icons.description_outlined,
              size: 16,
              color: c.muted,
            ),
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'Droves',
              applicationVersion: state.currentVersion,
              applicationLegalese: '© 2026 Muhammad Ihsan Ramadhan',
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(Space.md),
            child: Text(
              'Droves is a native client for your own bridge. It shows the panes '
              'already running on your machine, so no second agent runtime is '
              'started and nothing is uploaded anywhere.',
              style: monoStyle(context, size: 11, color: c.muted),
            ),
          ),
          const SizedBox(height: Space.xl),
        ],
      ),
    );
  }
}

Future<void> _applyUpdate(BuildContext context, UpdateInfo info) async {
  if (kIsWeb) {
    platform.reloadPage();
    return;
  }
  if (Theme.of(context).platform == TargetPlatform.iOS) {
    // the release asset is an APK; iOS updates go through whatever signed the app
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Open SideStore → My Apps, then tap update on Droves. Pull to refresh '
          'the source if ${info.latest} is not listed yet.',
          style: monoStyle(context, size: 12),
        ),
      ),
    );
    return;
  }
  final url = info.downloadUrl;
  if (url == null) return;
  await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
}

Future<void> _openRepo(BuildContext context) async {
  final uri = Uri.parse('https://github.com/ihsan-ramadhan/droves');
  final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(uri.toString(), style: monoStyle(context, size: 12)),
      ),
    );
  }
}

/// disconnect sits one tap from other settings, so it asks first
Future<void> _confirmDisconnect(BuildContext context, AppState state) async {
  final c = context.colors;
  final yes = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: c.paper,
      title: Text('Disconnect?', style: nameStyle(ctx, size: 18)),
      content: Text(
        'Droves stops reading this bridge. Saved bridges and their tokens stay '
        'on this device, so you can reconnect without retyping anything.',
        style: monoStyle(ctx, size: 12, color: c.muted),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(
            'Keep connected',
            style: monoStyle(ctx, size: 11, color: c.ink),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(
            'Disconnect',
            style: monoStyle(ctx, size: 11, color: c.accent),
          ),
        ),
      ],
    ),
  );
  if (yes == true) await state.disconnect();
}

/// shares prefs with the terminal's tune button; edits show up in either place
class _ShortcutSettings extends StatefulWidget {
  const _ShortcutSettings();

  @override
  State<_ShortcutSettings> createState() => _ShortcutSettingsState();
}

class _ShortcutSettingsState extends State<_ShortcutSettings> {
  List<String> _ids = defaultKeyIds;
  bool _enabled = false;

  @override
  void initState() {
    super.initState();
    KeyBarPrefs.loadKeys().then((ids) {
      if (mounted) setState(() => _ids = ids);
    });
    KeyBarPrefs.loadEnabled().then((value) {
      if (mounted) setState(() => _enabled = value);
    });
  }

  Future<void> _edit() async {
    final c = context.colors;
    final picked = await showModalBottomSheet<List<String>>(
      context: context,
      backgroundColor: c.paper,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.card)),
      ),
      builder: (_) => KeyBarPickerSheet(selected: _ids),
    );
    if (picked == null || !mounted) return;
    await KeyBarPrefs.saveKeys(picked);
    await KeyBarPrefs.saveEnabled(true);
    setState(() {
      _ids = picked;
      _enabled = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      children: [
        SwitchListTile(
          title: Text('Shortcut bar', style: monoStyle(context, size: 12)),
          subtitle: Text(
            'Show the key row above the terminal keyboard',
            style: monoStyle(context, size: 11, color: c.muted),
          ),
          value: _enabled,
          activeTrackColor: c.ink,
          onChanged: (value) async {
            setState(() => _enabled = value);
            await KeyBarPrefs.saveEnabled(value);
          },
        ),
        ListTile(
          title: Text('Shortcut keys', style: monoStyle(context, size: 12)),
          subtitle: Text(
            '${_ids.length} keys · also editable from a terminal',
            style: monoStyle(context, size: 11, color: c.muted),
          ),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: _edit,
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(
        Space.md,
        Space.lg,
        Space.md,
        Space.sm,
      ),
      child: LedgerLabel(label),
    );
  }
}
