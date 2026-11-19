// lists bridge methods each screen calls, to check README.md's parity table
import 'dart:io';

void main() {
  final pattern = RegExp(r"""['"]([a-z_]+(?:\.[a-z_]+)+)['"]""");
  final skip = RegExp(r'\.dart$');
  final byScreen = <String, Set<String>>{};
  for (final entity in Directory('lib/src/ui').listSync()) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final methods = pattern
        .allMatches(entity.readAsStringSync())
        .map((m) => m.group(1)!)
        .where((m) => !skip.hasMatch(m))
        .toSet();
    if (methods.isEmpty) continue;
    byScreen[entity.uri.pathSegments.last] = methods;
  }
  final all = <String>{};
  for (final entry in byScreen.entries) {
    final list = entry.value.toList()..sort();
    stdout.writeln('${entry.key.padRight(22)} ${list.join(', ')}');
    all.addAll(entry.value);
  }
  stdout.writeln('\ndistinct bridge methods: ${all.length}');
  final sorted = all.toList()..sort();
  stdout.writeln(sorted.join(' '));
}
