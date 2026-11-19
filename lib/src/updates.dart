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

/// the manifest lives beside the web app, served by the same bridge as the client
Uri? updateManifestUri(String baseUrl) {
  if (kIsWeb) return Uri.base.resolve('update.json');
  final base = Uri.tryParse(baseUrl);
  if (base == null || base.host.isEmpty) return null;
  return Uri.parse('${base.origin}/droves/update.json');
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
  return UpdateInfo(
    current: current,
    latest: latest,
    notes: (body['notes'] as String?)?.trim() ?? '',
    downloadUrl: apk == null || apk.isEmpty
        ? null
        : uri.resolve(apk).toString(),
  );
}
