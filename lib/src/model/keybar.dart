import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// one key the shortcut bar can send to a terminal
class TerminalKey {
  const TerminalKey(
    this.id,
    this.label,
    this.sequence, {
    this.group = 'Keys',
    this.sticky = false,
  });

  /// stable id for persistence; the label may change without losing prefs
  final String id;

  final String label;

  /// bytes written to the pane
  final String sequence;

  /// grouping in the picker
  final String group;

  /// sticky modifiers latch onto the next typed character instead of sending
  final bool sticky;
}

/// pickable catalogue; order is also the bar order
const terminalKeyCatalog = <TerminalKey>[
  TerminalKey('ctrl', 'Ctrl', '', group: 'Modifiers', sticky: true),
  TerminalKey('alt', 'Alt', '', group: 'Modifiers', sticky: true),
  TerminalKey('shift', 'Shift', '', group: 'Modifiers', sticky: true),
  TerminalKey('esc', 'Esc', '\x1b', group: 'Control'),
  TerminalKey('tab', 'Tab', '\t', group: 'Control'),
  TerminalKey('enter', 'Enter', '\r', group: 'Control'),
  TerminalKey('ctrl-c', 'C-c', '\x03', group: 'Control'),
  TerminalKey('ctrl-d', 'C-d', '\x04', group: 'Control'),
  TerminalKey('ctrl-l', 'C-l', '\x0c', group: 'Control'),
  TerminalKey('ctrl-r', 'C-r', '\x12', group: 'Control'),
  TerminalKey('ctrl-z', 'C-z', '\x1a', group: 'Control'),
  TerminalKey('ctrl-a', 'C-a', '\x01', group: 'Control'),
  TerminalKey('ctrl-e', 'C-e', '\x05', group: 'Control'),
  TerminalKey('ctrl-k', 'C-k', '\x0b', group: 'Control'),
  TerminalKey('ctrl-u', 'C-u', '\x15', group: 'Control'),
  TerminalKey('up', '↑', '\x1b[A', group: 'Arrows'),
  TerminalKey('down', '↓', '\x1b[B', group: 'Arrows'),
  TerminalKey('right', '→', '\x1b[C', group: 'Arrows'),
  TerminalKey('left', '←', '\x1b[D', group: 'Arrows'),
  TerminalKey('home', 'Home', '\x1b[H', group: 'Arrows'),
  TerminalKey('end', 'End', '\x1b[F', group: 'Arrows'),
  TerminalKey('pgup', 'PgUp', '\x1b[5~', group: 'Arrows'),
  TerminalKey('pgdn', 'PgDn', '\x1b[6~', group: 'Arrows'),
  TerminalKey('delete', 'Del', '\x1b[3~', group: 'Arrows'),
  TerminalKey('backspace', '⌫', '\x7f', group: 'Arrows'),
  // sent verbatim as literal text, not escape sequences
  TerminalKey('slash', '/', '/', group: 'Typos'),
  TerminalKey('pipe', '|', '|', group: 'Typos'),
  TerminalKey('tilde', '~', '~', group: 'Typos'),
  TerminalKey('dash', '-', '-', group: 'Typos'),
  TerminalKey('tab-complete', 'Tab Tab', '\t\t', group: 'Typos'),
];

/// defaults are keys most phone keyboards cannot produce: escape, interrupt, motion
const defaultKeyIds = <String>[
  'esc',
  'tab',
  'ctrl',
  'alt',
  'shift',
  'ctrl-c',
  'up',
  'down',
  'left',
  'right',
  'enter',
];

/// single typed character only; paste and control keys pass through untouched.
/// the caller clears the latch.
String applyStickyModifiers(Set<String> modifiers, String data) {
  if (modifiers.isEmpty || data.length != 1) return data;
  final unit = data.codeUnitAt(0);
  if (unit < 32 || unit > 126) return data;
  var out = data;
  if (modifiers.contains('shift')) out = out.toUpperCase();
  if (modifiers.contains('ctrl')) {
    final code = out.toUpperCase().codeUnitAt(0);
    if (code >= 64 && code <= 95) out = String.fromCharCode(code - 64);
  }
  if (modifiers.contains('alt')) out = '\x1b$out';
  return out;
}

TerminalKey? keyById(String id) {
  for (final key in terminalKeyCatalog) {
    if (key.id == id) return key;
  }
  return null;
}

/// persists which keys the bar shows, plus whether it is on
class KeyBarPrefs {
  static const _keys = 'droves.keybar.keys';
  static const _enabled = 'droves.keybar.enabled';

  static Future<List<String>> loadKeys() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keys);
    if (raw == null) return defaultKeyIds;
    final decoded = (jsonDecode(raw) as List).cast<String>();
    return decoded.where((id) => keyById(id) != null).toList();
  }

  static Future<void> saveKeys(List<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keys, jsonEncode(ids));
  }

  static Future<bool> loadEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_enabled) ?? false;
  }

  static Future<void> saveEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabled, value);
  }
}
