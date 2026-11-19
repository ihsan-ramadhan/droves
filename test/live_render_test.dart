@Tags(['live'])
library;

// renders real screens against a live bridge; skipped when no bridge answers
// run: flutter test --tags live --update-goldens test/live_render_test.dart
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:droves/src/bridge/bridge.dart';
import 'package:droves/src/model/app_state.dart';
import 'package:droves/src/theme/tokens.dart';
import 'package:droves/src/ui/agents_screen.dart';
import 'package:droves/src/ui/inbox_screen.dart';
import 'package:droves/src/ui/workspace_screen.dart';

const _base = 'https://icqn-arch.tail8022a8.ts.net';

String? _token() {
  final file = File(
    Platform.environment['DROVES_TOKEN_FILE'] ??
        '${Platform.environment['HOME']}/.config/bridge/token',
  );
  return file.existsSync() ? file.readAsStringSync().trim() : null;
}

String _materialIcons() {
  final flutter = File(Platform.resolvedExecutable);
  final root = flutter.parent.parent.parent.parent;
  return '${root.path}/artifacts/material_fonts/MaterialIcons-Regular.otf';
}

Future<void> _loadFonts() async {
  for (final entry in {
    'Fraunces': 'assets/fonts/Fraunces.ttf',
    'PlexMono': 'assets/fonts/IBMPlexMono-Regular.ttf',
    'MaterialIcons': _materialIcons(),
  }.entries) {
    final file = File(entry.value);
    if (!file.existsSync()) continue;
    final loader = FontLoader(entry.key)
      ..addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    await loader.load();
  }
}

void main() {
  late Bridge bridge;
  late AppState state;

  setUpAll(() async {
    await _loadFonts();
  });

  setUp(() async {
    // flutter_test stubs HttpClient; the live bridge needs the real one
    HttpOverrides.global = null;
    final token = _token();
    if (token == null) return;
    state = AppState();
    bridge = Bridge(Uri.parse(_base));
    await bridge.connect(token);
    state.bridge = bridge;
  });

  tearDown(() async {
    await bridge.dispose();
  });

  /// real bridge I/O; pump widgets inside runAsync
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 400)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
  }

  Widget host(Widget child) => AppScope(
    state: state,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: drovesTheme(Brightness.light),
      home: child,
    ),
  );

  testWidgets('inbox shows real workspaces', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(const InboxScreen()));
    await settle(tester);

    await expectLater(
      find.byType(InboxScreen),
      matchesGoldenFile('goldens/live-inbox.png'),
    );
  });

  testWidgets('agents shows real agent rows', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(const AgentsScreen()));
    await settle(tester);

    await expectLater(
      find.byType(AgentsScreen),
      matchesGoldenFile('goldens/live-agents.png'),
    );
  });

  testWidgets('workspace shows real panes and inspector', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    late List<WorkspaceInfo> workspaces;
    await tester.runAsync(() async {
      workspaces = await bridge.workspaces();
    });
    final withAgent = workspaces.firstWhere(
      (w) => w.paneCount > 0,
      orElse: () => workspaces.first,
    );

    await tester.pumpWidget(host(WorkspaceScreen(workspace: withAgent)));
    await settle(tester);

    await expectLater(
      find.byType(WorkspaceScreen),
      matchesGoldenFile('goldens/live-workspace.png'),
    );
  });
}
