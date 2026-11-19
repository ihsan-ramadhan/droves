/// Non-web fallback. The native path uses flutter_local_notifications.
bool get supported => false;

Future<String> permissionState() async => 'unsupported';

Future<bool> requestPermission() async => false;

Future<void> show(String title, String body) async {}
