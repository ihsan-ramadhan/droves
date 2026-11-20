import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'src/model/app_state.dart';
import 'src/notifications.dart';
import 'src/platform_web_stub.dart'
    if (dart.library.js_interop) 'src/platform_web.dart'
    as platform;
import 'src/theme/tokens.dart';
import 'src/ui/agents_screen.dart';
import 'src/ui/git_screen.dart';
import 'src/ui/inbox_screen.dart';
import 'src/ui/widgets.dart';
import 'src/updates.dart';
import 'src/bridge/bridge.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DrovesApp());
}

class DrovesApp extends StatefulWidget {
  const DrovesApp({super.key});

  @override
  State<DrovesApp> createState() => _DrovesAppState();
}

class _DrovesAppState extends State<DrovesApp> {
  final _state = AppState();
  ThemeMode _mode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    NotificationService.instance.init();
    _state.onNotice = _handleNotice;
    _state.loadVersion();
    _state.loadSaved().then((_) {
      if (mounted) setState(() => _mode = _state.themeMode);
      _state.checkForUpdates();
      if (_state.endpoints.isEmpty) return;
      _state.useEndpoint(_state.activeIndex).catchError((_) {});
    });
  }

  /// ranger notices are opt-in; a chat reply already reads on screen
  void _handleNotice(TaskNotice notice) {
    final s = _state;
    if (!s.notificationsEnabled || s.foreground) return;
    final wanted = switch (notice.kind) {
      'completed' => s.notifyCompleted,
      'blocked' => s.notifyBlocked,
      'ranger' => s.notifyRanger,
      _ => false,
    };
    if (wanted) NotificationService.instance.show(notice);
  }

  @override
  void dispose() {
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: _state,
      child: MaterialApp(
        title: 'Droves',
        debugShowCheckedModeBanner: false,
        theme: drovesTheme(Brightness.light),
        darkTheme: drovesTheme(Brightness.dark),
        themeMode: _mode,
        home: Shell(
          themeMode: _mode,
          onThemeChanged: (m) {
            setState(() => _mode = m);
            _state.setThemeMode(m);
          },
        ),
      ),
    );
  }
}

/// four destinations only; everything else is reached through a workspace
class Shell extends StatefulWidget {
  const Shell({
    super.key,
    required this.themeMode,
    required this.onThemeChanged,
  });

  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeChanged;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _index = 0;
  AppState? _state;
  String? _notifiedUpdate;
  bool _notificationPrompted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = AppScope.of(context);
    if (identical(next, _state)) return;
    _state?.removeListener(_onStateChanged);
    _state = next;
    next.addListener(_onStateChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _onStateChanged();
      _maybePromptNotifications();
    });
  }

  @override
  void dispose() {
    _state?.removeListener(_onStateChanged);
    super.dispose();
  }

  void _onStateChanged() {
    _maybePromptNotifications();
    final update = _state?.update;
    if (update == null || update.latest == _notifiedUpdate) return;
    _notifiedUpdate = update.latest;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Droves ${update.latest} is available',
            style: monoStyle(context, size: 12),
          ),
          duration: const Duration(seconds: 10),
          action: SnackBarAction(
            label: 'Update',
            onPressed: () => _installUpdate(update),
          ),
        ),
      );
    });
  }

  /// browser permission requires a tap; denied or unsupported turns the toggle off
  void _maybePromptNotifications() {
    final s = _state;
    if (s == null ||
        _notificationPrompted ||
        !s.notificationsEnabled ||
        s.endpoints.isEmpty) {
      return;
    }
    _notificationPrompted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (!NotificationService.instance.supported) {
        await s.setNotificationsEnabled(false);
        return;
      }
      final status = await NotificationService.instance.permissionState();
      if (!mounted) return;
      if (status == 'granted') return;
      if (!kIsWeb) {
        // Android reports "not asked yet" as denied; ask once, false turns the toggle off
        final granted = await NotificationService.instance.requestPermission();
        if (granted) {
          await s.setNotificationsEnabled(true);
          return;
        }
        await s.setNotificationsEnabled(false);
        return;
      }
      if (status == 'denied' || status == 'unsupported') {
        await s.setNotificationsEnabled(false);
        return;
      }
      final allow = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          backgroundColor: context.colors.paper,
          title: Text(
            'Turn on notifications?',
            style: nameStyle(context, size: 18),
          ),
          content: Text(
            'Get one alert when an agent finishes or needs your input, even '
            'when this tab is in the background.',
            style: monoStyle(context, size: 12, color: context.colors.muted),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialog).pop(false),
              child: const Text('Not now'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialog).pop(true),
              child: const Text('Allow'),
            ),
          ],
        ),
      );
      if (allow != true) {
        await s.setNotificationsEnabled(false);
        return;
      }
      final granted = await NotificationService.instance.requestPermission();
      if (!mounted) return;
      if (granted) {
        await s.setNotificationsEnabled(true);
        return;
      }
      await s.setNotificationsEnabled(false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Notifications are off. Allow them in browser settings.',
            style: monoStyle(context, size: 12),
          ),
        ),
      );
    });
  }

  void _installUpdate(UpdateInfo info) {
    if (kIsWeb) {
      platform.reloadPage();
      return;
    }
    final url = info.downloadUrl;
    if (url == null) return;
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  static const _destinations = [
    (Icons.inbox_outlined, Icons.inbox, 'Inbox'),
    (Icons.smart_toy_outlined, Icons.smart_toy, 'Agents'),
    (Icons.account_tree_outlined, Icons.account_tree, 'Changes'),
    (Icons.tune, Icons.tune, 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final wide = context.isWide;
    final body = switch (_index) {
      0 => const InboxScreen(),
      1 => const AgentsScreen(),
      2 => const _ChangesGate(),
      _ => SettingsScreen(
        themeMode: widget.themeMode,
        onThemeChanged: widget.onThemeChanged,
      ),
    };

    if (wide) {
      return Scaffold(
        backgroundColor: c.paper,
        body: Row(
          children: [
            NavigationRail(
              backgroundColor: c.paper,
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              labelType: NavigationRailLabelType.all,
              indicatorColor: c.ink,
              selectedIconTheme: IconThemeData(color: c.paper, size: 20),
              unselectedIconTheme: IconThemeData(color: c.muted, size: 20),
              destinations: [
                for (final d in _destinations)
                  NavigationRailDestination(
                    icon: Icon(d.$1),
                    selectedIcon: Icon(d.$2),
                    label: Text(d.$3, style: monoStyle(context, size: 10)),
                  ),
              ],
            ),
            VerticalDivider(color: c.rule, width: 1),
            Expanded(child: body),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: c.paper,
      body: body,
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: c.paper,
          border: Border(top: BorderSide(color: c.rule)),
        ),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 56,
            child: Row(
              children: [
                for (var i = 0; i < _destinations.length; i++)
                  Expanded(
                    child: InkWell(
                      onTap: () => setState(() => _index = i),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            _index == i
                                ? _destinations[i].$2
                                : _destinations[i].$1,
                            size: 20,
                            color: _index == i ? c.ink : c.muted,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _destinations[i].$3,
                            style: monoStyle(
                              context,
                              size: 9.5,
                              color: _index == i ? c.ink : c.muted,
                              weight: _index == i
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// one open workspace goes straight there; several asks which
class _ChangesGate extends StatefulWidget {
  const _ChangesGate();

  @override
  State<_ChangesGate> createState() => _ChangesGateState();
}

class _ChangesGateState extends State<_ChangesGate> {
  Future<List<WorkspaceInfo>>? _future;
  bool _reloading = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bridge = AppScope.of(context).bridge;
    if (bridge != null && _future == null) {
      _future = bridge.workspaces();
    }
  }

  Future<void> _reload() async {
    final bridge = AppScope.of(context).bridge;
    if (bridge == null) return;
    final next = bridge.workspaces();
    setState(() {
      _future = next;
      _reloading = true;
    });
    try {
      await next;
    } finally {
      if (mounted) setState(() => _reloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final future = _future;
    if (future == null) {
      return DrovesScaffold(
        title: 'Changes',
        child: StateMessage(
          headline: 'Not connected',
          body: 'Connect a bridge to read changes.',
          icon: Icons.account_tree_outlined,
        ),
      );
    }
    return FutureBuilder<List<WorkspaceInfo>>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const DrovesScaffold(
            title: 'Changes',
            child: SkeletonRows(rows: 6),
          );
        }
        if (snap.hasError) {
          return DrovesScaffold(
            title: 'Changes',
            child: StateMessage(
              headline: 'Could not list workspaces',
              body: snap.error.toString(),
              icon: Icons.error_outline,
            ),
          );
        }
        final list = snap.data ?? const [];
        if (list.isEmpty) {
          return DrovesScaffold(
            title: 'Changes',
            child: StateMessage(
              headline: 'No workspaces',
              body: 'Open a workspace on the machine first.',
              icon: Icons.inbox_outlined,
            ),
          );
        }
        if (list.length == 1) {
          final w = list.first;
          return GitScreen(workspace: w.workspaceId, label: w.label);
        }
        return DrovesScaffold(
          title: 'Changes',
          subtitle: const LedgerLabel('pick a workspace'),
          actions: [RefreshButton(busy: _reloading, onPressed: _reload)],
          child: RefreshIndicator(
            color: c.ink,
            onRefresh: _reload,
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: list.length,
              separatorBuilder: (_, _) => Divider(color: c.rule, height: 1),
              itemBuilder: (_, i) => ListTile(
                leading: Text(
                  list[i].number.toString().padLeft(2, '0'),
                  style: monoStyle(context, size: 11, color: c.muted),
                ),
                title: Text(list[i].label, style: nameStyle(context, size: 15)),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => GitScreen(
                      workspace: list[i].workspaceId,
                      label: list[i].label,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
