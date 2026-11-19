import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'bridge/bridge.dart';
import 'web_notify_stub.dart'
    if (dart.library.js_interop) 'web_notify_web.dart'
    as web_notify;

/// bridge relays task events over its socket; Android delivers nothing once the process is frozen
class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  static const _channelId = 'droves.tasks';
  static const _channelName = 'Agent activity';

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  int _nextId = 1;

  Future<void> init() async {
    if (_ready || kIsWeb) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: 'Finished agents, agents waiting on you, and Ranger runs.',
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
