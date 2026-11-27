import 'package:droves/src/model/terminal_wheel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a drag becomes sgr wheel reports at the viewport centre', () {
    final seq = wheelSequence(lines: -3, cols: 80, rows: 24);
    expect(seq, '\x1b[<64;40;12M');
  });

  test('dragging the other way sends wheel down', () {
    final seq = wheelSequence(lines: 3, cols: 80, rows: 24);
    expect(seq, '\x1b[<65;40;12M');
  });

  test('long drags send one notch per three rows', () {
    final seq = wheelSequence(lines: -30, cols: 80, rows: 24);
    expect(RegExp('\x1b\\[<64;40;12M').allMatches(seq).length, 10);
  });

  test('a capped drag cannot flood the pane', () {
    final seq = wheelSequence(lines: -3000, cols: 80, rows: 24);
    expect(RegExp('\x1b\\[<64;40;12M').allMatches(seq).length, 120);
  });

  test('nothing to send stays empty', () {
    expect(wheelSequence(lines: 0, cols: 80, rows: 24), '');
    expect(wheelSequence(lines: -3, cols: 1, rows: 24), '');
  });
}
