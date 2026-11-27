import 'package:droves/src/model/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final page = Uri.parse('https://icqn-arch.tail8022a8.ts.net:13030/droves/');

  test('a page mounted under /droves/ reaches its own origin', () {
    expect(
      sameOriginAsPage(
        'https://icqn-arch.tail8022a8.ts.net:13030/',
        page: page,
      ),
      isTrue,
    );
  });

  test('another host is refused', () {
    expect(
      sameOriginAsPage('https://other.tail8022a8.ts.net:13030/', page: page),
      isFalse,
    );
  });

  test('another port is refused', () {
    expect(
      sameOriginAsPage('https://icqn-arch.tail8022a8.ts.net:8443/', page: page),
      isFalse,
    );
  });

  test('another scheme is refused', () {
    expect(
      sameOriginAsPage('http://icqn-arch.tail8022a8.ts.net:13030/', page: page),
      isFalse,
    );
  });

  test('a malicious suffix does not pass', () {
    expect(
      sameOriginAsPage(
        'https://icqn-arch.tail8022a8.ts.net.evil.test:13030/',
        page: page,
      ),
      isFalse,
    );
  });
}
