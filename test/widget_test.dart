import 'package:flutter_test/flutter_test.dart';
import 'package:droves/src/bridge/bridge.dart';

void main() {
  test('workspace parses the bridge payload', () {
    final w = WorkspaceInfo.fromJson({
      'workspace_id': 'w1',
      'label': 'inventory',
      'number': 2,
      'pane_count': 3,
      'tab_count': 1,
      'agent_status': 'blocked',
    });
    expect(w.label, 'inventory');
    expect(w.number, 2);
    expect(w.agentStatus, 'blocked');
  });

  test('pane prefers the stripped title and falls back to cwd', () {
    final p = PaneInfo.fromJson({
      'pane_id': 'w1:p1',
      'terminal_id': 'term_1',
      'workspace_id': 'w1',
      'tab_id': 'w1:t1',
      'agent_status': 'working',
      'terminal_title_stripped': 'omp',
      'foreground_cwd': '/home/x/project',
    });
    expect(p.titleOrCwd, 'omp');
    expect(p.agentStatus, 'working');
  });

  test('terminal frame decodes base64 ANSI into text', () {
    final frame = TerminalFrame(
      terminalId: 'term_1',
      width: 80,
      height: 24,
      split: false,
      full: true,
      bytes: '\x1b[1mhi\x1b[0m',
    );
    expect(frame.bytes.contains('hi'), isTrue);
    expect(frame.full, isTrue);
  });
}
