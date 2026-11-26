// Contract checks for the Material 3 shell: real destinations and reduced motion.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:droves/main.dart';
import 'package:droves/src/model/app_state.dart';
import 'package:droves/src/ui/agents_screen.dart';
import 'package:droves/src/theme/tokens.dart';

void main() {
  Widget host({bool reduceMotion = false, Size? size}) => AppScope(
    state: AppState(),
    child: MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: MaterialApp(
        theme: drovesTheme(Brightness.light),
        builder: (context, child) => size == null
            ? child ?? const SizedBox.shrink()
            : MediaQuery(
                data: MediaQuery.of(context).copyWith(size: size),
                child: child ?? const SizedBox.shrink(),
              ),
        home: Shell(
          themeMode: ThemeMode.system,
          onThemeChanged: (_) {},
        ),
      ),
    ),
  );

  testWidgets('shell uses Material 3 navigation destinations', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationDestination), findsNWidgets(5));
    expect(find.text('Inbox'), findsWidgets);
    expect(find.text('Agents'), findsWidgets);
    expect(find.text('Scout'), findsWidgets);
    expect(find.text('Changes'), findsWidgets);
    expect(find.text('Settings'), findsWidgets);
  });

  testWidgets('destination switch updates selected index', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();

    final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(bar.selectedIndex, 0);

    await tester.tap(find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text('Settings'),
    ));
    await tester.pumpAndSettle();

    final updated = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(updated.selectedIndex, 4);
    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('destination switch has no transition animation', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();

    expect(find.byType(AnimatedSwitcher), findsNothing);
    expect(find.byType(SlideTransition), findsNothing);

    await tester.tap(find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text('Settings'),
    ));
    await tester.pump();

    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.byType(SlideTransition), findsNothing);
  });

  testWidgets('phone shell fits 360dp without overflow', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
  });

  testWidgets('wide shell uses Material 3 navigation rail', (tester) async {
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host(size: const Size(1024, 768)));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byType(NavigationRailDestination), findsNothing);
    final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
    expect(rail.destinations.length, 5);
  });
}
