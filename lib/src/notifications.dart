import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'bridge/bridge.dart';
import 'bridge/decode.dart';
import 'web_notify_stub.dart'
    if (dart.library.js_interop) 'web_notify_web.dart'
    as web_notify;

/// Converts a notification payload into the notice it refers to.
TaskNotice? noticeFromPayload(String? payload) {
  if (payload == null || payload.isEmpty) return null;
  try {
    final decoded = jsonDecode(payload) as Map<String, dynamic>;
    return TaskNotice(
      kind: (decoded['kind'] as String?) ?? 'completed',
      title: str(decoded['title']),
      body: str(decoded['body']),
      agent: decoded['agent'] as String?,
      workspaceId: decoded['workspaceId'] as String?,
      tabId: decoded['tabId'] as String?,
      paneId: decoded['paneId'] as String?,
    );
  } catch (_) {
    return null;
  }
}

/// bridge relays task events over its socket; Android delivers nothing once the process is frozen
class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  static const _channelId = 'droves.tasks';
  static const _channelName = 'Agent activity';
  static final MethodChannel _batteryChannel = const MethodChannel(
    'dev.droves.bridge/battery',
  );

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  int _nextId = 1;
  void Function(TaskNotice?)? _onNoticeTap;

  void _handleResponse(String? payload) {
    final notice = noticeFromPayload(payload);
    if (notice != null) _onNoticeTap?.call(notice);
  }

  Future<void> init({void Function(TaskNotice?)? onNoticeTap}) async {
    if (_ready || kIsWeb) return;
    _onNoticeTap = onNoticeTap;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: (response) {
        _handleResponse(response.payload);
      },
    );
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: 'Finished agents, agents waiting on you, and Scout runs.',
        importance: Importance.high,
      ),
    );
    _ready = true;
  }

  bool get supported => !kIsWeb || web_notify.supported;

  /// browser permission or Android's app-level switch; callers turn the setting off on denial
  Future<String> permissionState() async {
    if (kIsWeb) return web_notify.permissionState();
    await init();
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    final enabled = await android?.areNotificationsEnabled();
    return enabled == false ? 'denied' : 'granted';
  }

  /// Android 13+ asks once; the caller decides when
  Future<bool> requestPermission() async {
    if (kIsWeb) return web_notify.requestPermission();
    await init();
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    return await android?.requestNotificationsPermission() ?? true;
  }

  /// Android-only: whether the app is exempt from Doze/App Standby.
  /// Other platforms return true because there is no equivalent restriction.
  Future<bool> isIgnoringBatteryOptimizations() async {
    if (kIsWeb) return true;
    try {
      return await _batteryChannel.invokeMethod<bool>(
            'isIgnoringBatteryOptimizations',
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Android-only: opens the system prompt or settings for the battery
  /// allowlist. The user decides; this never changes the setting silently.
  Future<void> requestIgnoreBatteryOptimizations() async {
    if (kIsWeb) return;
    try {
      await _batteryChannel.invokeMethod('requestIgnoreBatteryOptimizations');
    } catch (_) {}
  }

  /// Notification that launched the app from a terminated state, if any.
  /// The plugin exposes this through getNotificationAppLaunchDetails.
  Future<TaskNotice?> launchNotice() async {
    if (kIsWeb) return null;
    final details = await _plugin.getNotificationAppLaunchDetails();
    return noticeFromPayload(details?.notificationResponse?.payload);
  }

  Future<void> show(TaskNotice notice) async {
    final isBlocked = notice.kind == 'blocked';
    final title = notice.title.isNotEmpty
        ? notice.title
        : (isBlocked ? 'Agent needs input' : 'Task completed');
    final body = [
      if (notice.agent != null && notice.agent!.isNotEmpty) notice.agent!,
      if (notice.body.isNotEmpty) notice.body,
    ].join(' · ');
    if (kIsWeb) {
      await web_notify.show(title, body);
      return;
    }
    await init();

    await _plugin.show(
      id: _nextId++,
      title: title,
      body: body.isEmpty ? null : body,
      payload: jsonEncode({
        'kind': notice.kind,
        'title': notice.title,
        'body': notice.body,
        'agent': notice.agent,
        'workspaceId': notice.workspaceId,
        'tabId': notice.tabId,
        'paneId': notice.paneId,
      }),
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          importance: Importance.high,
          priority: Priority.high,
          category: isBlocked
              ? AndroidNotificationCategory.reminder
              : AndroidNotificationCategory.progress,
          styleInformation: body.isEmpty ? null : BigTextStyleInformation(body),
        ),
      ),
    );
  }
}
