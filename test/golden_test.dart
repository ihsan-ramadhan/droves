// renders screens headlessly to test/goldens/; no pixel comparison in CI
// run: flutter test --update-goldens test/golden_test.dart
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:droves/src/model/app_state.dart';
import 'package:droves/src/bridge/bridge.dart';
import 'package:droves/src/theme/tokens.dart';
import 'package:droves/src/ui/agents_screen.dart';
import 'package:droves/src/ui/connect_screen.dart';
import 'package:droves/src/ui/inbox_screen.dart';
import 'package:droves/src/ui/widgets.dart';

Future<void> _loadFonts() async {
  for (final entry in {
    'Fraunces': 'assets/fonts/Fraunces.ttf',
    'PlexMono': 'assets/fonts/IBMPlexMono-Regular.ttf',
  }.entries) {
    final loader = FontLoader(entry.key)
      ..addFont(
        Future.value(ByteData.sublistView(File(entry.value).readAsBytesSync())),
      );
    await loader.load();
  }
}

Widget _host(Widget child, {Brightness brightness = Brightness.light}) {
  final state = AppState();
  return AppScope(
    state: state,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: drovesTheme(brightness),
      home: child,
    ),
  );
}

void main() {
  setUpAll(() async {
    await _loadFonts();
  });

  testWidgets('connect screen renders', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(const ConnectScreen()));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(ConnectScreen),
      matchesGoldenFile('goldens/connect.png'),
    );
  });

  testWidgets('inbox disconnected state renders', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(const InboxScreen()));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(InboxScreen),
      matchesGoldenFile('goldens/inbox-disconnected.png'),
    );
  });

  testWidgets('inbox disconnected state renders in dark mode', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _host(const InboxScreen(), brightness: Brightness.dark),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(InboxScreen),
      matchesGoldenFile('goldens/inbox-disconnected-dark.png'),
    );
  });

  testWidgets('agents empty state renders', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(const AgentsScreen()));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(AgentsScreen),
      matchesGoldenFile('goldens/agents-empty.png'),
    );
  });

  testWidgets('workspace row renders with tally marks', (tester) async {
    tester.view.physicalSize = const Size(1080, 620);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(const SizedBox.shrink()));
    final ctx = tester.element(find.byType(SizedBox));
    await tester.pumpWidget(
      _host(
        Scaffold(
          body: Column(
            children: [
              for (final row in [
                ('inventory', 1, 'blocked'),
                ('billing', 2, 'working'),
                ('notes', 3, 'unknown'),
              ])
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  child: Row(
                    children: [
                      Text(
                        row.$2.toString().padLeft(2, '0'),
                        style: monoStyle(ctx, size: 11),
                      ),
                      const SizedBox(width: 10),
                      TallyRail(
                        workspaces: [
                          WorkspaceInfo(
                            workspaceId: row.$1,
                            label: row.$1,
                            number: row.$2,
                            paneCount: 1,
                            tabCount: 1,
                            agentStatus: row.$3,
                          ),
                        ],
                        max: 1,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(row.$1, style: nameStyle(ctx, size: 16.5)),
                      ),
                      StatusWord(row.$3),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/rows.png'),
    );
  });
}
