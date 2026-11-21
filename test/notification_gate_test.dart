import 'package:flutter_test/flutter_test.dart';

import 'package:droves/main.dart';
import 'package:droves/src/bridge/bridge.dart';

void main() {
  TaskNotice notice(String kind) =>
      TaskNotice(kind: kind, title: 't', body: '');

  group('shouldNotify', () {
    test('completed shows while the app is visible', () {
      expect(
        shouldNotify(
          notice('completed'),
          enabled: true,
          hidden: false,
          completed: true,
          blocked: true,
          scout: true,
        ),
        isTrue,
      );
    });

    test('completed shows when the app is hidden', () {
      expect(
        shouldNotify(
          notice('completed'),
          enabled: true,
          hidden: true,
          completed: true,
          blocked: true,
          scout: true,
        ),
        isTrue,
      );
    });

    test('blocked shows even in another workspace', () {
      expect(
        shouldNotify(
          notice('blocked'),
          enabled: true,
          hidden: false,
          completed: true,
          blocked: true,
          scout: true,
        ),
        isTrue,
      );
    });

    test('disabled and per-kind toggles are respected', () {
      expect(
        shouldNotify(
          notice('scout'),
          enabled: false,
          hidden: true,
          completed: true,
          blocked: true,
          scout: true,
        ),
        isFalse,
      );
      expect(
        shouldNotify(
          notice('scout'),
          enabled: true,
          hidden: true,
          completed: true,
          blocked: true,
          scout: false,
        ),
        isFalse,
      );
    });
  });
}
