import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:droves/src/notifications.dart';

void main() {
  test('notification payload keeps the target pane', () {
    final payload = jsonEncode({
      'kind': 'blocked',
      'title': 'Agent needs input',
      'body': 'workspaces',
      'agent': 'pi',
      'workspaceId': 'wE:pC',
      'tabId': 't1',
      'paneId': 'p3',
    });
    final notice = noticeFromPayload(payload);
    expect(notice, isNotNull);
    expect(notice!.kind, 'blocked');
    expect(notice.workspaceId, 'wE:pC');
    expect(notice.tabId, 't1');
    expect(notice.paneId, 'p3');
  });

  test('notification payload tolerates missing and malformed values', () {
    expect(noticeFromPayload(null), isNull);
    expect(noticeFromPayload(''), isNull);
    expect(noticeFromPayload('not json'), isNull);
    final notice = noticeFromPayload('{}');
    expect(notice, isNotNull);
    expect(notice!.kind, 'completed');
    expect(notice.paneId, isNull);
  });
}
