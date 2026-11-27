import 'package:droves/src/bridge/bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('joins a trailing-slash base without doubling', () {
    final base = Uri.parse('https://host:13030/');
    expect(
      bridgeUri(base, 'api/terminal-upload').toString(),
      'https://host:13030/api/terminal-upload',
    );
    expect(bridgeUri(base, 'ws').toString(), 'https://host:13030/ws');
  });

  test('keeps a mounted prefix', () {
    final base = Uri.parse('https://host/droves/');
    expect(
      bridgeUri(base, 'api/login').toString(),
      'https://host/droves/api/login',
    );
    expect(bridgeUri(base, 'api/login').path, '/droves/api/login');
  });

  test('works without a trailing slash too', () {
    final base = Uri.parse('https://host:13030');
    expect(
      bridgeUri(base, 'api/info').toString(),
      'https://host:13030/api/info',
    );
  });

  test('carries query parameters', () {
    final uri = bridgeUri(
      Uri.parse('https://host/'),
      'api/terminal-upload',
      query: {'filename': 'photo one.jpg'},
    );
    expect(uri.path, '/api/terminal-upload');
    expect(uri.queryParameters['filename'], 'photo one.jpg');
  });
}
