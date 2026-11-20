import 'package:material_ui/material_ui.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:mermaid_core/mermaid_core.dart' show MermaidTheme;
import 'package:mermaid_flutter/mermaid_flutter.dart';

import '../theme/tokens.dart';

/// mermaid fences become diagrams; other code blocks render as selectable text
class MermaidMarkdownBuilder extends MarkdownElementBuilder {
  MermaidMarkdownBuilder();

  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    md.Element? code;
    for (final child in element.children ?? const <md.Node>[]) {
      if (child is md.Element && child.tag == 'code') {
        code = child;
        break;
      }
    }
    final source = code?.textContent.trim() ?? element.textContent.trim();
    if (code != null &&
        (code.attributes['class'] ?? '')
            .split(' ')
            .contains('language-mermaid') &&
        source.isNotEmpty) {
      return MermaidBlock(source: source);
    }
    if (source.isEmpty) return null;
    final c = context.colors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Space.sm),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.rule),
        borderRadius: BorderRadius.circular(Radii.row),
      ),
      child: SelectableText(source, style: monoStyle(context, size: 11.5)),
    );
  }
}

class MermaidBlock extends StatelessWidget {
  const MermaidBlock({super.key, required this.source});

  final String source;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: Space.xs),
      decoration: BoxDecoration(
        color: c.paper,
        border: Border.all(color: c.rule),
        borderRadius: BorderRadius.circular(Radii.row),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.sm, 6, Space.sm, 0),
            child: Row(
              children: [
                Icon(Icons.account_tree_outlined, size: 13, color: c.muted),
                const SizedBox(width: 4),
                LedgerLabel('mermaid'),
              ],
            ),
          ),
          SizedBox(
            height: 340,
            child: MermaidView(
              source: source,
              theme: dark ? MermaidTheme.darkTheme : MermaidTheme.defaultTheme,
              errorBuilder: (context, error) => SingleChildScrollView(
                padding: const EdgeInsets.all(Space.sm),
                child: SelectableText(
                  source,
                  style: monoStyle(context, size: 11, color: c.muted),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
