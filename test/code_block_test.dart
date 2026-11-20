import 'package:material_ui/material_ui.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;

import 'package:droves/src/theme/tokens.dart';
import 'package:droves/src/ui/mermaid_block.dart';

void main() {
  testWidgets('non-mermaid fenced code blocks render their text', (
    tester,
  ) async {
    const code = 'add commit flow, notifications and mobile UX';
    await tester.pumpWidget(
      MaterialApp(
        theme: drovesTheme(Brightness.light),
        home: Scaffold(
          body: MarkdownBody(
            data: '```text\n$code\n```',
            selectable: true,
            extensionSet: md.ExtensionSet.gitHubFlavored,
            builders: {'pre': MermaidMarkdownBuilder()},
          ),
        ),
      ),
    );

    expect(find.text(code), findsOneWidget);
  });
}
