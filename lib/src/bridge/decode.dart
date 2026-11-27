/// rpc payloads arrive as untyped maps. These keep the casts in one place so a
/// screen never writes `(r['x'] as List?)?.cast<Map<String, dynamic>>()` again.
library;

List<Map<String, dynamic>> maps(Object? raw) =>
    ((raw as List?) ?? const []).cast<Map<String, dynamic>>();

List<String> strings(Object? raw) =>
    ((raw as List?) ?? const []).cast<String>();

String str(Object? raw, [String fallback = '']) =>
    raw is String ? raw : fallback;

String? strOrNull(Object? raw) => raw is String ? raw : null;

int? integer(Object? raw) => raw is num ? raw.toInt() : null;

int whole(Object? raw, [int fallback = 0]) => integer(raw) ?? fallback;

bool flag(Object? raw) => raw == true;
