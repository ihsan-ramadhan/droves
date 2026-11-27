import 'dart:async';

import 'package:flutter/foundation.dart'
    show
        LicenseEntryWithLineBreaks,
        LicenseRegistry,
        defaultTargetPlatform,
        kIsWeb,
        TargetPlatform;
import 'package:flutter/services.dart' show rootBundle;
// ignore: deprecated_member_use
import 'package:flutter/material.dart' as sdk_material;
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'src/model/app_state.dart';
import 'src/notifications.dart';
import 'src/platform_web_stub.dart'
    if (dart.library.js_interop) 'src/platform_web.dart'
    as platform;
import 'src/bridge/bridge.dart';
import 'src/theme/tokens.dart';
import 'src/ui/agents_screen.dart';
import 'src/ui/chat_screen.dart';
import 'src/ui/common/scaffold.dart';
import 'src/ui/common/state_message.dart';
import 'src/ui/dialogs.dart';
import 'src/ui/git_screen.dart';
import 'src/ui/inbox_screen.dart';
import 'src/ui/scout_screen.dart';
import 'src/updates.dart';

bool shouldNotify(
  TaskNotice notice, {
  required bool enabled,
  required bool hidden,
  required bool completed,
  required bool blocked,
  required bool scout,
}) {
  if (!enabled) return false;
  final wanted = switch (notice.kind) {
    'completed' => completed,
    'blocked' => blocked,
    'scout' => scout,
    _ => false,
  };
  // blocked needs an answer, so it always notifies; completed is short-lived
  // enough that the user should hear about it even with the app open
  return wanted &&
      (hidden || notice.kind == 'blocked' || notice.kind == 'completed');
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (defaultTargetPlatform == TargetPlatform.android) {
    TextMagnifier.adaptiveMagnifierConfiguration =
        TextMagnifierConfiguration.disabled;
    sdk_material.TextMagnifier.adaptiveMagnifierConfiguration =
        sdk_material.TextMagnifierConfiguration.disabled;
  }
  // OFL requires the notice to travel with the fonts, including inside the
  // installed app; the license page is where a user can actually read it
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(const [
      'Droves bundled fonts',
    ], await rootBundle.loadString('assets/fonts/OFL.txt'));
  });
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
    unawaited(
      NotificationService.instance.init(
        onNoticeTap: (notice) {
          if (notice != null) _state.tappedNotice = notice;
        },
      ),
    );
    _state.onNotice = _handleNotice;
    _state.loadVersion();
    _state.loadSaved().then((_) {
      if (mounted) setState(() => _mode = _state.themeMode);
      _state.checkForUpdates();
      unawaited(_handleLaunchNotification());
      if (_state.endpoints.isEmpty) return;
      _state.useEndpoint(_state.activeIndex).catchError((_) {});
    });
  }

  /// completed and blocked always notify; scout waits until the app is hidden
  /// because its run already has a progress surface in the UI
  void _handleNotice(TaskNotice notice) {
    final s = _state;
    final hidden = kIsWeb ? platform.pageHidden : !s.foreground;
    if (shouldNotify(
      notice,
      enabled: s.notificationsEnabled,
      hidden: hidden,
      completed: s.notifyCompleted,
      blocked: s.notifyBlocked,
      scout: s.notifyScout,
    )) {
      unawaited(NotificationService.instance.show(notice));
    }
  }

  Future<void> _handleLaunchNotification() async {
    final notice = await NotificationService.instance.launchNotice();
    if (notice != null) _state.tappedNotice = notice;
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
        localizationsDelegates: const [
          sdk_material.DefaultMaterialLocalizations.delegate,
        ],
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
  bool _visibilityHooked = false;
  bool _notificationPrompted = false;

  @override
  void initState() {
    super.initState();
    if (kIsWeb && !_visibilityHooked) {
      _visibilityHooked = true;
      platform.onAppVisible(() {
        if (!mounted || _state == null) return;
        unawaited(_state!.checkForUpdates(silent: false));
      });
    }
  }

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
    final s = _state;
    final tapped = s?.tappedNotice;
    if (tapped != null && s!.bridge?.state == BridgeState.ready) {
      s.tappedNotice = null;
      unawaited(_openNoticePane(tapped));
    }
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
            label: kIsWeb ? 'Load update' : 'Update',
            onPressed: () => _installUpdate(update),
          ),
        ),
      );
    });
  }

  Future<void> _openNoticePane(TaskNotice notice) async {
    final bridge = _state?.bridge;
    if (bridge == null || bridge.state != BridgeState.ready) return;
    final workspaceId = notice.workspaceId;
    if (workspaceId == null || workspaceId.isEmpty) return;
    try {
      final panes = await bridge.panes(workspaceId);
      PaneInfo? pane;
      if (notice.paneId != null && notice.paneId!.isNotEmpty) {
        for (final p in panes) {
          if (p.paneId == notice.paneId) {
            pane = p;
            break;
          }
        }
      }
      final target = pane ?? panes.firstOrNull;
      if (target == null || !mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              ChatScreen(pane: target, label: notice.agent ?? notice.title),
        ),
      );
    } catch (_) {}
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
      final allow = await confirmDialog(
        context,
        title: 'Turn on notifications?',
        body:
            'Get one alert when an agent finishes or needs your input, even '
            'when this tab is in the background.',
        cancelLabel: 'Not now',
        confirmLabel: 'Allow',
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
      unawaited(platform.reloadPage());
      return;
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      unawaited(
        launchUrl(
          Uri.parse('https://github.com/ihsan-ramadhan/droves/releases/latest'),
          mode: LaunchMode.externalApplication,
        ),
      );
      return;
    }
    final url = info.downloadUrl;
    if (url == null) return;
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  static const _destinations = [
    (Icons.inbox_outlined, Icons.inbox, 'Inbox'),
    (Icons.smart_toy_outlined, Icons.smart_toy, 'Agents'),
    (Icons.travel_explore_outlined, Icons.travel_explore, 'Scout'),
    (Icons.account_tree_outlined, Icons.account_tree, 'Changes'),
    (Icons.tune, Icons.tune, 'Settings'),
  ];

  Widget _body(int index) => switch (index) {
    0 => const InboxScreen(),
    1 => const AgentsScreen(),
    2 => const ScoutScreen(),
    3 => const _ChangesGate(),
    _ => SettingsScreen(
      themeMode: widget.themeMode,
      onThemeChanged: widget.onThemeChanged,
    ),
  };

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final wide = context.isWide;
    final body = _body(_index);

    if (wide) {
      return Scaffold(
        backgroundColor: c.paper,
        body: SafeArea(
          child: Row(
            children: [
              NavigationRail(
                selectedIndex: _index,
                onDestinationSelected: (i) => setState(() => _index = i),
                labelType: NavigationRailLabelType.all,
                useIndicator: true,
                minWidth: 80,
                destinations: [
                  for (final d in _destinations)
                    NavigationRailDestination(
                      icon: Icon(d.$1),
                      selectedIcon: Icon(d.$2),
                      label: Text(d.$3),
                    ),
                ],
              ),
              VerticalDivider(color: c.rule, width: 1),
              Expanded(child: body),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: c.paper,
      body: SafeArea(top: false, bottom: false, child: body),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          for (final d in _destinations)
            NavigationDestination(
              icon: Icon(d.$1),
              selectedIcon: Icon(d.$2),
              label: d.$3,
            ),
        ],
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
  Bridge? _bound;
  bool _wasReady = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppScope.of(context);
    final bridge = app.bridge;
    final ready = bridge != null && app.state == BridgeState.ready;
    // a bridge that dropped and came back still has a stale failed future;
    // reading workspaces again on the transition is what clears it
    if (!identical(bridge, _bound) || (ready && !_wasReady)) {
      _bound = bridge;
      _future = ready ? bridge.workspaces() : null;
    }
    _wasReady = ready;
  }

  Future<void> _reload() async {
    final app = AppScope.of(context);
    final bridge = app.bridge;
    if (bridge == null || bridge.state != BridgeState.ready) {
      await app.reconnect().catchError((_) {});
      if (!mounted) return;
    }
    final live = AppScope.of(context).bridge;
    if (live == null || live.state != BridgeState.ready) {
      setState(() => _future = null);
      return;
    }
    final next = live.workspaces();
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
    final state = AppScope.of(context);
    // every other tab hands a dead bridge to the same widget, so Changes must
    // not invent its own "could not read" wording while the bridge is down
    if (state.bridge == null || state.state != BridgeState.ready) {
      final status = connectionSubtitle(context, null);
      return DrovesScaffold(
        title: 'Changes',
        subtitle: LedgerLabel(status.isEmpty ? 'not connected' : status),
        child: Center(child: BridgeDownState(onRetry: _reload)),
      );
    }
    final future = _future;
    if (future == null) {
      return DrovesScaffold(
        title: 'Changes',
        subtitle: const LedgerLabel('reading workspaces'),
        child: ScreenState(
          loading: true,
          error: null,
          connected: true,
          empty: false,
          subject: 'workspaces',
          emptyHeadline: '',
          emptyBody: '',
          onRetry: _reload,
        ),
      );
    }
    return FutureBuilder<List<WorkspaceInfo>>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done || snap.hasError) {
          return DrovesScaffold(
            title: 'Changes',
            child: ScreenState(
              loading: snap.connectionState != ConnectionState.done,
              error: snap.hasError ? snap.error.toString() : null,
              connected: true,
              empty: false,
              subject: 'workspaces',
              emptyHeadline: '',
              emptyBody: '',
              onRetry: _reload,
              rows: 6,
            ),
          );
        }
        final list = snap.data ?? const [];
        if (list.isEmpty) {
          return DrovesScaffold(
            title: 'Changes',
            child: ScreenState(
              loading: false,
              error: null,
              connected: true,
              empty: true,
              subject: 'changes',
              emptyHeadline: 'No workspaces',
              emptyBody: 'Open a workspace on the machine first.',
              onRetry: _reload,
              emptyIcon: Icons.inbox_outlined,
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
