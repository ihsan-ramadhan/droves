String wheelSequence({
  required int lines,
  required int cols,
  required int rows,
  int notchesCap = 120,
}) {
  if (lines == 0 || cols < 2 || rows < 2) return '';
  final col = (cols ~/ 2).clamp(1, cols);
  final row = (rows ~/ 2).clamp(1, rows);
  final notches = (lines.abs() / 3).ceil().clamp(1, notchesCap);
  final code = lines < 0 ? 64 : 65;
  final buffer = StringBuffer();
  for (var i = 0; i < notches; i++) {
    buffer.write('\x1b[<$code;$col;${row}M');
  }
  return buffer.toString();
}
