enum FailureKind {
  auth,
  dns,
  refused,
  timeout,
  tls,
  offline,
  closed,
  http,
  unknown,
}

class Failure {
  const Failure(this.kind, {this.host = '', this.code = ''});

  final FailureKind kind;
  final String host;
  final String code;

  String get body => switch (kind) {
    FailureKind.auth => 'That token was rejected. Check it and try again.',
    FailureKind.dns =>
      "Can't find $_where. Check the address and any VPN or tunnel it needs, "
          'then try again.',
    FailureKind.refused =>
      '${_whereFor(capital: true)} is not answering. Start the bridge on that '
          'machine, then try again.',
    FailureKind.timeout =>
      '${_whereFor(capital: true)} took too long to answer. Check the network '
          'and try again.',
    FailureKind.tls =>
      "This phone rejected the bridge's certificate. If it uses a self-signed "
          'one, trust that certificate on the phone first.',
    FailureKind.offline =>
      "This phone can't reach the bridge. Check Wi-Fi or mobile data, then "
          'try again.',
    FailureKind.closed =>
      'The bridge closed the connection. It may have restarted; try again.',
    FailureKind.http =>
      code.isEmpty
          ? 'The bridge returned an error. Try again in a moment.'
          : 'The bridge returned an error ($code). Try again in a moment.',
    FailureKind.unknown =>
      'Something went wrong talking to the bridge. Try '
          'again.',
  };

  String get tag => switch (kind) {
    FailureKind.auth => 'token rejected',
    FailureKind.dns => "can't find $_where",
    FailureKind.refused => 'bridge not running',
    FailureKind.timeout => 'no answer',
    FailureKind.tls => 'certificate rejected',
    FailureKind.offline => 'no network',
    FailureKind.closed => 'connection dropped',
    FailureKind.http => code.isEmpty ? 'bridge error' : 'bridge error $code',
    FailureKind.unknown => 'connection failed',
  };

  String get _where => host.isEmpty ? 'the bridge' : host;

  String _whereFor({required bool capital}) {
    if (host.isEmpty) return capital ? 'The bridge' : 'the bridge';
    return host;
  }
}

Failure classifyFailure(Object? error, {Uri? base}) {
  final raw = error?.toString() ?? '';
  final text = raw.toLowerCase();
  final host = _hostIn(raw, base);
  final code = RegExp(r'\((\d{3})\)').firstMatch(raw)?.group(1) ?? '';

  if (text.isEmpty) return const Failure(FailureKind.unknown);
  if (text.contains('login rejected') || text.contains('(401)')) {
    return Failure(FailureKind.auth, host: host);
  }
  if (text.contains('failed host lookup') ||
      text.contains('no address associated') ||
      text.contains('name or service not known') ||
      text.contains('nodename nor servname')) {
    return Failure(FailureKind.dns, host: host);
  }
  if (text.contains('connection refused')) {
    return Failure(FailureKind.refused, host: host);
  }
  if (text.contains('timed out') || text.contains('timeout')) {
    return Failure(FailureKind.timeout, host: host);
  }
  if (text.contains('certificate') ||
      text.contains('handshake') ||
      text.contains('tls')) {
    return Failure(FailureKind.tls, host: host);
  }
  if (text.contains('unreachable') || text.contains('no route to host')) {
    return Failure(FailureKind.offline, host: host);
  }
  if (text.contains('connection closed') ||
      text.contains('not connected') ||
      text.contains('socket has been closed') ||
      text.contains('websocket')) {
    return Failure(FailureKind.closed, host: host);
  }
  if (code.isNotEmpty) return Failure(FailureKind.http, host: host, code: code);
  return Failure(FailureKind.unknown, host: host);
}

String friendlyFailure(Object? error, {Uri? base}) =>
    classifyFailure(error, base: base).body;

String failureTag(Object? error, {Uri? base}) =>
    classifyFailure(error, base: base).tag;

String friendlyErrorText(
  Object? error, {
  Uri? base,
  String fallback = 'Something went wrong. Try again.',
}) {
  final failure = classifyFailure(error, base: base);
  if (failure.kind != FailureKind.unknown) return failure.body;
  var text = (error?.toString() ?? '')
      .replaceFirst(RegExp(r'^\w*(Exception|Error):\s*'), '')
      .trim();
  final json = text.indexOf('{');
  if (json > 0) text = text.substring(0, json).trim();
  text = text.replaceAll(RegExp(r'\s+'), ' ');
  if (text.isEmpty) return fallback;
  const limit = 140;
  if (text.length > limit) {
    final cut = text.lastIndexOf(' ', limit);
    text = '${text.substring(0, cut < 60 ? limit : cut)}\u2026';
  }
  return text;
}

String _hostIn(String raw, Uri? base) {
  if (base != null && base.host.isNotEmpty) return base.host;
  final match = RegExp(r'uri=[a-z]+://([^/\s,]+)').firstMatch(raw);
  if (match != null) return match.group(1)!;
  final lookup = RegExp(r"Failed host lookup: '([^']+)'").firstMatch(raw);
  return lookup?.group(1) ?? '';
}
