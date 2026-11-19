import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../bridge/bridge.dart';
import '../updates.dart';

/// one saved bridge; the endpoint is what Droves dials,
/// the connection is what it reads inside it
class Endpoint {
  Endpoint({required this.url, required this.token, this.label = ''});

  final String url;
  final String token;
  final String label;

  String get displayLabel {
    if (label.isNotEmpty) return label;
    final host = Uri.tryParse(url)?.host;
    return (host == null || host.isEmpty) ? url : host;
  }

  Map<String, dynamic> toJson() => {'url': url, 'token': token, 'label': label};

  factory Endpoint.fromJson(Map<String, dynamic> j) => Endpoint(
    url: (j['url'] as String?) ?? '',
    token: (j['token'] as String?) ?? '',
    label: (j['label'] as String?) ?? '',
  );
}

/// persistent connection settings plus the live bridge handle
class AppState extends ChangeNotifier with WidgetsBindingObserver {
  AppState();

  static const _kEndpoints = 'droves.endpoints';
  static const _kActive = 'droves.active_endpoint';
  static const _kNotify = 'droves.notify_enabled';
  static const _kNotifyCompleted = 'droves.notify_completed';
  static const _kNotifyBlocked = 'droves.notify_blocked';
  static const _kNotifyRanger = 'droves.notify_ranger';
  static const _kAutoReconnect = 'droves.auto_reconnect';
  static const _kThemeMode = 'droves.theme_mode';

  Bridge? bridge;

  /// every saved bridge, most recently used first
  List<Endpoint> endpoints = const [];

  /// index into [endpoints] for the live connection
  int activeIndex = 0;

  // read on every event; kept in memory, written back only on change
  bool notificationsEnabled = true;
  bool notifyCompleted = true;
  bool notifyBlocked = true;
  bool notifyRanger = false;
  bool autoReconnect = true;

  /// persisted so a restart keeps the theme
  ThemeMode themeMode = ThemeMode.system;

  /// runtime identity and the latest build advertised by the serving bridge
  String currentVersion = '';
  UpdateInfo? update;
  bool updateChecking = false;
  String? updateError;
  DateTime? lastUpdateCheck;

  bool _reconnecting = false;
  bool _disposed = false;

  /// false in the background; notifications only when the user can't see the screen
  bool foreground = true;

  /// set by `main` so the bridge relays task events without importing the notification plugin
  void Function(TaskNotice notice)? onNotice;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    // Android drops backgrounded sockets silently; dial again on resume
    if (state == AppLifecycleState.resumed) {
      _probeOnResume();
      checkForUpdates();
    }
  }

  /// Chrome can freeze a tab and kill its socket silently; ping to prove
  /// the link, failure flips state and schedules the reconnect
  Future<void> _probeOnResume() async {
    final current = bridge;
    if (current != null && current.state == BridgeState.ready) {
      try {
        await current.call('bridge.ping', const {}, const Duration(seconds: 5));
        return;
      } catch (_) {}
    }
    await _ensureConnected();
  }

  Endpoint? get active => (activeIndex >= 0 && activeIndex < endpoints.length)
      ? endpoints[activeIndex]
      : null;

  String get baseUrl => active?.url ?? '';
  String get token => active?.token ?? '';

  bool get connected => bridge?.state == BridgeState.ready;
  BridgeState get state => bridge?.state ?? BridgeState.idle;
  String? get error => bridge?.lastError;

  Future<void> loadSaved() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_kEndpoints) ?? const [];
    final saved = <Endpoint>[];
    for (final entry in raw) {
      try {
        final j = jsonDecode(entry);
        if (j is Map<String, dynamic>) saved.add(Endpoint.fromJson(j));
      } catch (_) {
        // a corrupt entry must not cost the user the other endpoints
      }
    }
    endpoints = saved;
    final stored = prefs.getInt(_kActive) ?? 0;
    activeIndex = (stored >= 0 && stored < saved.length) ? stored : 0;
    notificationsEnabled = prefs.getBool(_kNotify) ?? true;
    notifyCompleted = prefs.getBool(_kNotifyCompleted) ?? true;
    notifyBlocked = prefs.getBool(_kNotifyBlocked) ?? true;
    notifyRanger = prefs.getBool(_kNotifyRanger) ?? false;
    autoReconnect = prefs.getBool(_kAutoReconnect) ?? true;
    themeMode = switch (prefs.getString(_kThemeMode)) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    WidgetsBinding.instance.addObserver(this);
    notifyListeners();
  }

  Future<void> loadVersion() async {
    try {
      currentVersion = await currentAppVersion();
      notifyListeners();
    } catch (_) {
      // package metadata is optional; leave the Settings row blank
    }
  }

  /// silent checks: offline or no manifest must not error over the user's screen
  Future<void> checkForUpdates({bool silent = true}) async {
    if (updateChecking) return;
    final checked = lastUpdateCheck;
    if (silent &&
        checked != null &&
        DateTime.now().difference(checked) < const Duration(hours: 6)) {
      return;
    }
    if (currentVersion.isEmpty) await loadVersion();
    updateChecking = true;
    if (!silent) updateError = null;
    notifyListeners();
    try {
      final info = await checkForUpdate(
        current: currentVersion,
        baseUrl: baseUrl,
      );
      update = info != null && info.isNewer ? info : null;
      updateError = null;
      lastUpdateCheck = DateTime.now();
    } catch (_) {
      if (!silent) {
        updateError = 'Could not check for updates.';
      }
    } finally {
      updateChecking = false;
      notifyListeners();
    }
  }

  Future<void> setNotificationsEnabled(bool value) async {
    notificationsEnabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kNotify, value);
  }

  Future<void> setNotifyCompleted(bool value) async {
    notifyCompleted = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kNotifyCompleted, value);
  }

  Future<void> setNotifyBlocked(bool value) async {
    notifyBlocked = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kNotifyBlocked, value);
  }

  Future<void> setNotifyRanger(bool value) async {
    notifyRanger = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kNotifyRanger, value);
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kThemeMode, switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    });
  }

  Future<void> setAutoReconnect(bool value) async {
    autoReconnect = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoReconnect, value);
  }

  /// bounded retries with backoff: a resume can land before the network is up
  Future<void> _ensureConnected() async {
    if (_disposed || !autoReconnect || endpoints.isEmpty) return;
    // a redial in flight owns the swap; joining would dispose its half-built socket
    while (_reconnecting) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (_disposed) return;
    }
    final current = bridge;
    if (current != null &&
        (current.state == BridgeState.ready ||
            current.state == BridgeState.connecting)) {
      return;
    }
    _reconnecting = true;
    try {
      for (var attempt = 0; attempt < 5; attempt++) {
        if (_disposed) return;
        try {
          await useEndpoint(activeIndex);
          return;
        } catch (_) {
          if (attempt == 4) return;
          await Future<void>.delayed(Duration(milliseconds: 400 << attempt));
        }
      }
    } finally {
      _reconnecting = false;
    }
  }

  /// live socket closed on its own
  void _onBridgeState(BridgeState state) {
    notifyListeners();
    if (state == BridgeState.idle && autoReconnect) {
      Future<void>.delayed(const Duration(seconds: 2), _ensureConnected);
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kEndpoints, [
      for (final e in endpoints) jsonEncode(e.toJson()),
    ]);
    await prefs.setInt(_kActive, activeIndex);
  }

  /// re-adding the same URL replaces the stored token instead of growing the list
  Future<void> connect(String url, String password, {String label = ''}) async {
    final normalised = url.trim().endsWith('/') ? url.trim() : '${url.trim()}/';
    final uri = Uri.parse(normalised);
    if (!uri.hasScheme || uri.host.isEmpty) {
      throw BridgeError('Enter a host like https://machine.tailnet.ts.net');
    }
    final trimmedToken = password.trim();
    final next = Bridge(uri);
    next.redial = () => useEndpoint(activeIndex);
    await bridge?.dispose();
    bridge = next;
    notifyListeners();
    next.stateStream.listen(_onBridgeState);
    next.notices.listen((notice) => onNotice?.call(notice));
    try {
      await next.connect(trimmedToken);
    } catch (_) {
      notifyListeners();
      rethrow;
    }
    final entry = Endpoint(
      url: uri.toString(),
      token: trimmedToken,
      label: label,
    );
    final rest = [...endpoints]..removeWhere((e) => e.url == entry.url);
    endpoints = [entry, ...rest];
    activeIndex = 0;
    await _persist();
    notifyListeners();
  }

  /// dials an already-saved endpoint
  Future<void> useEndpoint(int index) async {
    if (index < 0 || index >= endpoints.length) return;
    final target = endpoints[index];
    await connect(target.url, target.token, label: target.label);
  }

  Future<void> forgetEndpoint(int index) async {
    if (index < 0 || index >= endpoints.length) return;
    final removingActive = index == activeIndex;
    endpoints = [...endpoints]..removeAt(index);
    if (endpoints.isEmpty) {
      activeIndex = 0;
    } else if (index < activeIndex) {
      activeIndex -= 1;
    } else if (index == activeIndex) {
      activeIndex = 0;
    }
    if (removingActive) {
      await bridge?.dispose();
      bridge = null;
    }
    await _persist();
    notifyListeners();
  }

  Future<void> disconnect() async {
    await bridge?.dispose();
    bridge = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

/// makes [AppState] available without pulling in a package
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child})
    : super(notifier: state);

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
}
