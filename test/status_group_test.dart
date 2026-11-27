import 'package:droves/src/ui/common/status_group.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('working, done, idle order with blocked first', () {
    final sections = statusSections([
      'idle',
      'done',
      'working',
      'blocked',
      'idle',
    ], (s) => s);

    expect(sections.map((s) => s.group), [
      StatusGroup.working,
      StatusGroup.done,
      StatusGroup.idle,
    ]);
    expect(sections[0].items, ['blocked', 'working']);
    expect(sections[1].items, ['done']);
    expect(sections[2].items, ['idle', 'idle']);
  });

  test('empty bands are dropped instead of leaving a header', () {
    final sections = statusSections(['done', 'done'], (s) => s);

    expect(sections, hasLength(1));
    expect(sections.single.group, StatusGroup.done);
    expect(sections.single.items, ['done', 'done']);
  });

  test('unknown status falls into idle', () {
    expect(statusGroupOf('unknown'), StatusGroup.idle);
    expect(statusGroupOf(''), StatusGroup.idle);
  });
}
