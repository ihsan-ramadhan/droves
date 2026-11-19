import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// iOS: Home Screen web apps on 16.4+ only; permission request must ride a user gesture
bool get supported {
  try {
    return web.Notification.permission.isNotEmpty;
  } catch (_) {
    return false;
  }
}

/// `granted`, `denied`, `default`, or `unsupported` without a Notification API
Future<String> permissionState() async {
  try {
    return web.Notification.permission;
  } catch (_) {
    return 'unsupported';
  }
}

Future<bool> requestPermission() async {
  try {
    if (web.Notification.permission == 'granted') return true;
    if (web.Notification.permission == 'denied') return false;
    final result = await web.Notification.requestPermission().toDart;
    return result.toDart == 'granted';
  } catch (_) {
    return false;
  }
}

Future<void> show(String title, String body) async {
  if (web.Notification.permission != 'granted') return;
  final options = web.NotificationOptions(
    body: body,
    icon: 'icons/Icon-192.png',
    tag: 'droves-task',
  );
  // mobile browsers only show service-worker notifications; constructor is a desktop fallback
  try {
    final registration = await web.window.navigator.serviceWorker.ready.toDart;
    await registration.showNotification(title, options).toDart;
    return;
  } catch (_) {}
  try {
    web.Notification(title, options);
  } catch (_) {
    // permission may have been lost between the event and this call
  }
}
