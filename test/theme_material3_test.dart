import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:droves/src/theme/tokens.dart';

double _relativeLuminance(Color color) {
  double channel(double value) {
    final c = value;
    return c <= 0.03928
        ? c / 12.92
        : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * channel(color.r) +
      0.7152 * channel(color.g) +
      0.0722 * channel(color.b);
}

double _contrast(Color a, Color b) {
  final l1 = _relativeLuminance(a);
  final l2 = _relativeLuminance(b);
  return (l1 > l2 ? l1 + 0.05 : l2 + 0.05) / (l1 > l2 ? l2 + 0.05 : l1 + 0.05);
}

void main() {
  for (final brightness in Brightness.values) {
    test('Material 3 ${brightness.name} scheme has readable core roles', () {
      final theme = drovesTheme(brightness);
      final scheme = theme.colorScheme;
      final tokens = theme.extension<DrovesColors>()!;

      expect(theme.useMaterial3, isTrue);
      expect(scheme.primary, tokens.accent);
      expect(
        _contrast(scheme.onPrimary, scheme.primary),
        greaterThanOrEqualTo(4.5),
      );
      expect(_contrast(tokens.ink, tokens.paper), greaterThanOrEqualTo(4.5));
      expect(_contrast(tokens.muted, tokens.paper), greaterThanOrEqualTo(4.5));
      expect(theme.navigationBarTheme.indicatorColor, isNotNull);
      expect(theme.appBarTheme.toolbarHeight, 64);
    });
  }
}
