import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:droves/src/bridge/bridge.dart';
import 'package:droves/src/model/app_state.dart';
import 'package:droves/src/theme/tokens.dart';
import 'package:droves/src/ui/agents_screen.dart';
import 'package:droves/src/ui/files_screen.dart';
import 'package:droves/src/ui/scout_screen.dart';
import 'package:droves/src/ui/workspace_screen.dart';

Widget host(Widget child) => AppScope(
  state: AppState(),
  child: MaterialApp(theme: drovesTheme(Brightness.light), home: child),
);

void main() {
  testWidgets('agents hides bridge actions before a bridge exists', (
    tester,
  ) async {
    await tester.pumpWidget(host(const AgentsScreen()));
    await tester.pump();

    expect(find.text('Bridge is not connected'), findsOneWidget);
    expect(find.byTooltip('Refresh'), findsNothing);
  });

  testWidgets('scout hides its toolbar and composer before a bridge exists', (
    tester,
  ) async {
    await tester.pumpWidget(host(const ScoutScreen()));
    await tester.pump();

    expect(find.text('Bridge is not connected'), findsOneWidget);
    expect(find.byTooltip('Refresh'), findsNothing);
    expect(find.byTooltip('Pick model'), findsNothing);
    expect(find.byTooltip('New chat'), findsNothing);
    expect(find.byTooltip('Send'), findsNothing);
  });

  testWidgets('workspace hides its actions before a bridge exists', (
    tester,
  ) async {
    final workspace = WorkspaceInfo(
      workspaceId: 'w1',
      label: 'box',
      number: 1,
      paneCount: 1,
      tabCount: 1,
      agentStatus: 'idle',
    );
    await tester.pumpWidget(host(WorkspaceScreen(workspace: workspace)));
    await tester.pump();

    expect(find.text('Bridge is not connected'), findsOneWidget);
    expect(find.byTooltip('New tab'), findsNothing);
    expect(find.byTooltip('Search this workspace'), findsNothing);
  });

  testWidgets('files hides its actions before a bridge exists', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      host(const FilesScreen(workspace: 'w1', label: 'box')),
    );
    await tester.pump();

    expect(find.text('Bridge is not connected'), findsOneWidget);
    expect(find.byTooltip('New'), findsNothing);
    expect(find.byTooltip('Show hidden files'), findsNothing);
  });
}
