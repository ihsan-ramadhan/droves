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

  test('plain keys keep their bare sequence', () {
    for (final id in ['left', 'up', 'pgup', 'delete']) {
      final key = keyById(id)!;
      expect(applyModifiersToKey(const {}, key), key.sequence);
    }
  });

  test('cursor keys carry the xterm modifier parameter', () {
    expect(applyModifiersToKey({'ctrl'}, keyById('left')!), '\x1b[1;5D');
    expect(applyModifiersToKey({'shift'}, keyById('up')!), '\x1b[1;2A');
    expect(applyModifiersToKey({'alt'}, keyById('right')!), '\x1b[1;3C');
    expect(applyModifiersToKey({'ctrl', 'shift'}, keyById('right')!), '\x1b[1;6C');
  });

  test('home, end and paging encode the same way', () {
    expect(applyModifiersToKey({'ctrl'}, keyById('home')!), '\x1b[1;5H');
    expect(applyModifiersToKey({'ctrl'}, keyById('end')!), '\x1b[1;5F');
    expect(applyModifiersToKey({'alt'}, keyById('pgup')!), '\x1b[5;3~');
    expect(applyModifiersToKey({'ctrl'}, keyById('delete')!), '\x1b[3;5~');
  });

  test('shift turns tab into reverse tab', () {
    expect(applyModifiersToKey({'shift'}, keyById('tab')!), '\x1b[Z');
    expect(applyModifiersToKey({'ctrl'}, keyById('tab')!), '\t');
  });
}
