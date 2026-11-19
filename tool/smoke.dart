// end-to-end smoke check against a live bridge. run:
//   BRIDGE_URL=https://host.tailnet.ts.net BRIDGE_TOKEN=… dart run tool/smoke.dart
import 'dart:io';

import 'package:droves/src/bridge/bridge.dart';

Future<void> main(List<String> args) async {
  final base = args.isNotEmpty
      ? args[0]
      : (Platform.environment['BRIDGE_URL'] ?? '');
  final token = args.length > 1
      ? args[1]
      : (Platform.environment['BRIDGE_TOKEN'] ?? '');
  if (base.isEmpty || token.isEmpty) {
    stderr.writeln(
      'usage: BRIDGE_URL=… BRIDGE_TOKEN=… dart run tool/smoke.dart',
    );
    exit(64);
  }

  final bridge = Bridge(Uri.parse(base));
  var frames = 0;
  String? firstFrame;

  await bridge.connect(token);
  stdout.writeln(
    'connected: ${bridge.state.name} connection=${bridge.connectionId}',
  );

  final workspaces = await bridge.workspaces();
  stdout.writeln(
    'workspaces: ${workspaces.length} first=${workspaces.isEmpty ? '-' : workspaces.first.label}',
  );

  final panes = await bridge.panes(workspaces.first.workspaceId);
  stdout.writeln('panes: ${panes.length}');

  final sub = bridge.frames.listen((f) {
    frames++;
    firstFrame ??=
        '${f.width}x${f.height} full=${f.full} len=${f.bytes.length}';
  });

  await bridge.attach(panes.first.terminalId, 80, 24);
  await Future<void>.delayed(const Duration(milliseconds: 2500));
  stdout.writeln('frames: $frames first=$firstFrame');

  final agents = await bridge.call('agent.list');
  final list = (agents['agents'] as List?) ?? const [];
  stdout.writeln('agents: ${list.length}');

  await sub.cancel();
  await bridge.detach(panes.first.terminalId);
  await bridge.dispose();
  stdout.writeln(frames > 0 ? 'SMOKE OK' : 'SMOKE FAILED: no frames');
  exit(frames > 0 ? 0 : 1);
}
