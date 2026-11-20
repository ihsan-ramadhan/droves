import 'dart:js_interop';

import 'package:web/web.dart' as web;

bool get pageHidden => web.document.hidden;

void openExternalLink(Uri uri) {
  final isStandalone = web.window
      .matchMedia('(display-mode: standalone)')
      .matches;
  final isIOS =
      web.window.navigator.userAgent.contains('iPhone') ||
      web.window.navigator.userAgent.contains('iPad');
  if (isStandalone && isIOS) {
    web.window.location.href = 'x-safari-$uri';
    return;
  }
  final anchor = web.document.createElement('a') as web.HTMLAnchorElement
    ..href = uri.toString()
    ..target = '_blank'
    ..rel = 'noopener noreferrer';
  anchor.click();
}

void onAppVisible(void Function() callback) {
  web.document.addEventListener(
    'visibilitychange',
    ((web.Event _) {
      if (!web.document.hidden) callback();
    }).toJS,
  );
  web.window.addEventListener('pageshow', ((web.Event _) => callback()).toJS);
}

Future<void> reloadPage() async {
  try {
    final registration = await web.window.navigator.serviceWorker
        .getRegistration()
        .toDart;
    await registration?.update().toDart;
  } catch (_) {}
  web.window.location.reload();
}
