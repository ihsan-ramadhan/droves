import 'package:material_ui/material_ui.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mermaid_flutter/mermaid_flutter.dart';

import 'package:droves/src/theme/tokens.dart';
import 'package:droves/src/ui/mermaid_block.dart';

Widget _host(String markdown) {
  return MaterialApp(
    theme: drovesTheme(Brightness.light),
    home: Scaffold(
      body: SingleChildScrollView(
        child: MarkdownBody(
          data: markdown,
          builders: {'pre': MermaidMarkdownBuilder()},
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('mermaid fence renders a diagram instead of source', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host('```mermaid\nflowchart TD\n  A[Start] --> B[Done]\n```'),
    );
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(MermaidView), findsOneWidget);
    expect(find.textContaining('flowchart TD'), findsNothing);
  });

  testWidgets('other fences keep the code renderer', (tester) async {
    await tester.pumpWidget(_host('```dart\nvoid main() {}\n```'));
    await tester.pump();

    expect(find.byType(MermaidView), findsNothing);
    expect(find.byType(MermaidBlock), findsNothing);
  });
}
