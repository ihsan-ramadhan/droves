import 'package:droves/src/bridge/failure.dart';
import 'package:flutter_test/flutter_test.dart';

const _dnsDump =
    "ClientException with SocketException: Failed host lookup: "
    "'instabox-main.tail8022a8.ts.net' (OS Error: No address associated with "
    'hostname, errno = 7), '
    'uri=https://instabox-main.tail8022a8.ts.net:13031/api/login';

void main() {
  test('a dns dump becomes a reachability hint with the host named', () {
    final failure = classifyFailure(
      _dnsDump,
      base: Uri.parse('https://instabox-main.tail8022a8.ts.net:13031/'),
    );
    expect(failure.kind, FailureKind.dns);
    expect(failure.body, contains('instabox-main.tail8022a8.ts.net'));
    expect(failure.body, contains('VPN or tunnel'));
    expect(failure.body, isNot(contains('Tailscale')));
    expect(failure.body, isNot(contains('errno')));
    expect(failure.body, isNot(contains('uri=')));
    expect(failure.body, isNot(contains('Exception')));
  });

  test('the host survives when only the exception carries it', () {
    final failure = classifyFailure(_dnsDump);
    expect(failure.body, contains('instabox-main.tail8022a8.ts.net:13031'));
  });

  test('a refused socket points at the bridge process', () {
    final body = friendlyFailure(
      'SocketException: Connection refused (OS Error: Connection refused, '
      'errno = 111)',
      base: Uri.parse('https://box.ts.net:13031/'),
    );
    expect(body, contains('box.ts.net'));
    expect(body, contains('Start the bridge'));
  });

  test('a rejected token is named as a token problem', () {
    final failure = classifyFailure('Login rejected (401). Check the token.');
    expect(failure.kind, FailureKind.auth);
    expect(failure.body, contains('token'));
    expect(failure.body, isNot(contains('401')));
  });

  test('slow and dropped transports read like sentences', () {
    expect(
      friendlyFailure('BridgeError: read timed out'),
      contains('too long to answer'),
    );
    expect(
      friendlyFailure('BridgeError: Connection closed'),
      contains('closed the connection'),
    );
    expect(
      friendlyFailure('SocketException: Network is unreachable'),
      contains("can't reach the bridge"),
    );
    expect(
      friendlyFailure('HandshakeException: certificate verify failed'),
      contains('certificate'),
    );
  });

  test('an http code stays visible but loses the payload', () {
    final text = friendlyErrorText(
      'Upload failed (413): {"error":"too big","trace":["a","b"]}',
    );
    expect(text, contains('413'));
    expect(text, isNot(contains('{')));
    expect(text.length, lessThan(160));
  });

  test('a long non transport message is trimmed at a word boundary', () {
    final text = friendlyErrorText('BridgeError: ${'word ' * 60}');
    expect(text.length, lessThanOrEqualTo(141));
    expect(text, endsWith('word…'));
  });

  test('nothing usable falls back to one short sentence', () {
    expect(friendlyErrorText(null), 'Something went wrong. Try again.');
    expect(
      friendlyFailure(''),
      'Something went wrong talking to the bridge. '
      'Try again.',
    );
  });

  test('the subtitle tag stays a few words', () {
    for (final tag in [
      failureTag(_dnsDump, base: Uri.parse('https://box.ts.net:13031/')),
      failureTag('Login rejected (401)'),
      failureTag('BridgeError: read timed out'),
      failureTag('unknown thing'),
    ]) {
      expect(tag, isNotEmpty);
      expect(tag.split(' ').length, lessThanOrEqualTo(3));
    }
  });
}
