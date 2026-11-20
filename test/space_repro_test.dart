import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

import 'package:droves/src/ui/terminal_screen.dart';

void main() {
  test('shift+space reaches the pty as a space', () {
    final t = Terminal(maxLines: 100);
    t.inputHandler = drovesInputHandler;
    final out = StringBuffer();
    t.onOutput = out.write;
    final consumed = t.keyInput(TerminalKey.space, shift: true);
    expect(consumed, isTrue);
    expect(out.toString(), ' ');
  });

  test('plain space still reaches the pty', () {
    final t = Terminal(maxLines: 100);
    t.inputHandler = drovesInputHandler;
    final out = StringBuffer();
    t.onOutput = out.write;
    t.keyInput(TerminalKey.space);
    expect(out.toString(), ' ');
  });

  test('ctrl+space keeps sending NUL', () {
    final t = Terminal(maxLines: 100);
    t.inputHandler = drovesInputHandler;
    final out = StringBuffer();
    t.onOutput = out.write;
    t.keyInput(TerminalKey.space, ctrl: true);
    expect(out.toString(), '\x00');
  });
}
