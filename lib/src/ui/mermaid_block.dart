import 'package:material_ui/material_ui.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:mermaid_core/mermaid_core.dart' show MermaidTheme;
import 'package:mermaid_flutter/mermaid_flutter.dart';

import '../theme/tokens.dart';

/// ```mermaid fences become pan/zoom diagrams; other `pre` blocks use the default renderer
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
    if (code == null) return null;
    final language = (code.attributes['class'] ?? '').split(' ');
    if (!language.contains('language-mermaid')) return null;
    final source = code.textContent.trim();
    if (source.isEmpty) return null;
    return MermaidBlock(source: source);
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
