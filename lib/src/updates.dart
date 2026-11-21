import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

class UpdateInfo {
  const UpdateInfo({
    required this.current,
    required this.latest,
    required this.notes,
    this.downloadUrl,
  });

  final String current;
  final String latest;
  final String notes;
  final String? downloadUrl;

  bool get isNewer => compareVersions(latest, current) > 0;
}

/// numeric dotted comparison; the build suffix is not a release boundary
int compareVersions(String a, String b) {
  final left = a.split('+').first.split('.').map(int.tryParse).toList();
  final right = b.split('+').first.split('.').map(int.tryParse).toList();
  for (var i = 0; i < 3; i++) {
    final l = i < left.length ? (left[i] ?? 0) : 0;
    final r = i < right.length ? (right[i] ?? 0) : 0;
    if (l != r) return l.compareTo(r);
  }
  return 0;
}

Future<String> currentAppVersion() async {
  final info = await PackageInfo.fromPlatform();
  return info.version;
}

const String githubReleaseBase =
    'https://github.com/ihsan-ramadhan/droves/releases/latest/download';

/// Web reads its manifest from the bridge origin so the session cookie and the
/// served bundle stay together. Native builds read the release manifest
/// directly: a bridge can be offline or stale, but the release is canonical.
Uri? updateManifestUri(String baseUrl) {
  if (kIsWeb) return Uri.base.resolve('update.json');
  return Uri.parse('$githubReleaseBase/update.json');
}

/// null when unreadable or no release; a failed check must never interrupt the app
Future<UpdateInfo?> checkForUpdate({
  required String current,
  String baseUrl = '',
}) async {
  final uri = updateManifestUri(baseUrl);
  if (uri == null) return null;
  final response = await http.get(uri).timeout(const Duration(seconds: 8));
  if (response.statusCode != 200) return null;
  final body = jsonDecode(response.body);
  if (body is! Map<String, dynamic>) return null;
  final latest = (body['version'] as String?)?.trim();
  if (latest == null || latest.isEmpty) return null;

  final apk = (body['android_arm64'] ?? body['android_arm']) as String?;
  final String? downloadUrl;
  if (apk == null || apk.isEmpty) {
    downloadUrl = null;
  } else if (kIsWeb) {
    downloadUrl = uri.resolve(apk).toString();
  } else {
    // the release manifest uses "download/<asset>" relative to the release root
    final releaseRoot = Uri.parse(
      'https://github.com/ihsan-ramadhan/droves/releases/latest/',
    );
    downloadUrl = releaseRoot.resolve(apk).toString();
  }
  return UpdateInfo(
    current: current,
    latest: latest,
    notes: (body['notes'] as String?)?.trim() ?? '',
    downloadUrl: downloadUrl,
  );
}
