import 'package:droves/src/model/keybar.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('shift uppercases one letter', () {
    expect(applyStickyModifiers({'shift'}, 'a'), 'A');
  });

  test('ctrl maps letters to control bytes', () {
    expect(applyStickyModifiers({'ctrl'}, 'c'), '\x03');
    expect(applyStickyModifiers({'ctrl'}, 'd'), '\x04');
  });

  test('alt prefixes escape', () {
    expect(applyStickyModifiers({'alt'}, 'b'), '\x1bb');
  });

  test('combination applies ctrl before alt', () {
    expect(applyStickyModifiers({'ctrl', 'alt'}, 'a'), '\x1b\x01');
  });

  test('control keys and pastes pass through', () {
    expect(applyStickyModifiers({'ctrl'}, '\r'), '\r');
    expect(applyStickyModifiers({'shift'}, 'abc'), 'abc');
  });
}
