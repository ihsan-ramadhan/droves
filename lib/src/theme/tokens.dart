import 'package:material_ui/material_ui.dart';

/// design tokens; DESIGN.md holds the reason behind each value
@immutable
class DrovesColors extends ThemeExtension<DrovesColors> {
  const DrovesColors({
    required this.ink,
    required this.paper,
    required this.surface,
    required this.muted,
    required this.rule,
    required this.accent,
    required this.terminalBg,
    required this.terminalFg,
  });

  final Color ink;
  final Color paper;
  final Color surface;
  final Color muted;
  final Color rule;
  final Color accent;
  final Color terminalBg;
  final Color terminalFg;

  static const light = DrovesColors(
    ink: Color(0xFF1B1A17),
    paper: Color(0xFFF4EFE4),
    surface: Color(0xFFFBF8F1),
    muted: Color(0xFF6E675C),
    rule: Color(0xFFD9D1C1),
    accent: Color(0xFFA8471F),
    terminalBg: Color(0xFF23211D),
    terminalFg: Color(0xFFEDE8DE),
  );

  static const dark = DrovesColors(
    ink: Color(0xFFEDE8DE),
    paper: Color(0xFF151412),
    surface: Color(0xFF1D1B18),
    muted: Color(0xFF9A9184),
    rule: Color(0xFF332F29),
    accent: Color(0xFFD9642F),
    terminalBg: Color(0xFF100F0D),
    terminalFg: Color(0xFFEDE8DE),
  );

  @override
  DrovesColors copyWith({
    Color? ink,
    Color? paper,
    Color? surface,
    Color? muted,
    Color? rule,
    Color? accent,
    Color? terminalBg,
    Color? terminalFg,
  }) {
    return DrovesColors(
      ink: ink ?? this.ink,
      paper: paper ?? this.paper,
      surface: surface ?? this.surface,
      muted: muted ?? this.muted,
      rule: rule ?? this.rule,
      accent: accent ?? this.accent,
      terminalBg: terminalBg ?? this.terminalBg,
      terminalFg: terminalFg ?? this.terminalFg,
    );
  }

  @override
  DrovesColors lerp(ThemeExtension<DrovesColors>? other, double t) {
    if (other is! DrovesColors) return this;
    return DrovesColors(
      ink: Color.lerp(ink, other.ink, t)!,
      paper: Color.lerp(paper, other.paper, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      rule: Color.lerp(rule, other.rule, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      terminalBg: Color.lerp(terminalBg, other.terminalBg, t)!,
      terminalFg: Color.lerp(terminalFg, other.terminalFg, t)!,
    );
  }
}

/// spacing scale, four steps for a phone-first app
abstract final class Space {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const xl = 40.0;
}

abstract final class Radii {
  /// square-ish ledger motif, not pills
  static const row = 3.0;
  static const card = 6.0;
}


extension DrovesTheme on BuildContext {
  DrovesColors get colors => Theme.of(this).extension<DrovesColors>()!;
  bool get isWide => MediaQuery.sizeOf(this).width >= 900;
  bool get isTablet => MediaQuery.sizeOf(this).width >= 700;
}

ThemeData drovesTheme(Brightness brightness) {
  final c = brightness == Brightness.dark
      ? DrovesColors.dark
      : DrovesColors.light;
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme:
        ColorScheme.fromSeed(
          seedColor: c.accent,
          brightness: brightness,
        ).copyWith(
          surface: c.surface,
          primary: c.accent,
          onSurface: c.ink,
          // Android selection handles and the copy toolbar must not inherit the seed palette's pale tones; keep them readable on paper and terminal
          secondary: c.accent,
          onSecondary: c.paper,
        ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: c.accent,
      selectionColor: c.accent.withValues(alpha: 0.35),
      selectionHandleColor: c.accent,
    ),
  );
  return base.copyWith(
    scaffoldBackgroundColor: c.paper,
    extensions: [c],
    dividerTheme: DividerThemeData(color: c.rule, thickness: 1, space: 1),
    textTheme: base.textTheme.apply(bodyColor: c.ink, displayColor: c.ink),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: c.surface,
      contentTextStyle: TextStyle(
        fontFamily: 'PlexMono',
        fontSize: 12,
        color: c.ink,
      ),
      actionTextColor: c.accent,
    ),
    splashFactory: NoSplash.splashFactory,
  );
}

/// the only uppercase in the app, small and tracked tightly
class LedgerLabel extends StatelessWidget {
  const LedgerLabel(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        fontFamily: 'PlexMono',
        fontSize: 10,
        height: 1.3,
        letterSpacing: 0.8,
        fontWeight: FontWeight.w600,
        color: color ?? context.colors.muted,
      ),
    );
  }
}

/// Fraunces for names, wherever the user reads their own labels
TextStyle nameStyle(
  BuildContext context, {
  double size = 16,
  FontWeight weight = FontWeight.w500,
}) {
  return TextStyle(
    fontFamily: 'Fraunces',
    // terminal titles carry Nerd Font private-use glyphs; without fallback they render as boxes
    fontFamilyFallback: const ['JetBrainsMonoNerd', 'NotoColorEmoji'],
    fontSize: size,
    height: 1.25,
    fontWeight: weight,
    color: context.colors.ink,
    fontVariations: const [
      FontVariation('opsz', 24),
      FontVariation('SOFT', 30),
    ],
  );
}

TextStyle monoStyle(
  BuildContext context, {
  double size = 12,
  Color? color,
  FontWeight weight = FontWeight.w400,
}) {
  return TextStyle(
    fontFamily: 'PlexMono',
    // terminal tooling puts private-use glyphs in titles and paths; Nerd Font fallback avoids tofu
    fontFamilyFallback: const ['JetBrainsMonoNerd', 'NotoColorEmoji'],
    fontSize: size,
    height: 1.45,
    fontWeight: weight,
    color: color ?? context.colors.ink,
  );
}
