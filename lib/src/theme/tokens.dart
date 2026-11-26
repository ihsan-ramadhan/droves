import 'package:material_ui/material_ui.dart';

/// M3-aligned design tokens; DESIGN.md holds the reason behind each value
@immutable
class DrovesColors extends ThemeExtension<DrovesColors> {
  const DrovesColors({
    required this.ink,
    required this.paper,
    required this.surface,
    required this.muted,
    required this.rule,
    required this.accent,
    required this.error,
    required this.terminalBg,
    required this.terminalFg,
  });

  final Color ink;
  final Color paper;
  final Color surface;
  final Color muted;
  final Color rule;
  final Color accent;
  final Color error;
  final Color terminalBg;
  final Color terminalFg;

  static const _seed = Color(0xFFA8471F);
  static Color get seed => _seed;

  static final light = DrovesColors._fromScheme(
    brightness: Brightness.light,
    paper: const Color(0xFFF4EFE4),
    terminalBg: const Color(0xFF23211D),
    terminalFg: const Color(0xFFEDE8DE),
  );

  static final dark = DrovesColors._fromScheme(
    brightness: Brightness.dark,
    paper: const Color(0xFF151412),
    terminalBg: const Color(0xFF100F0D),
    terminalFg: const Color(0xFFEDE8DE),
  );

  factory DrovesColors._fromScheme({
    required Brightness brightness,
    required Color paper,
    required Color terminalBg,
    required Color terminalFg,
  }) {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: brightness,
    );
    return DrovesColors(
      ink: scheme.onSurface,
      paper: paper,
      surface: brightness == Brightness.dark
          ? const Color(0xFF1D1B18)
          : const Color(0xFFFBF8F1),
      muted: scheme.onSurfaceVariant,
      rule: scheme.outlineVariant,
      accent: scheme.primary,
      error: scheme.error,
      terminalBg: terminalBg,
      terminalFg: terminalFg,
    );
  }


  @override
  DrovesColors copyWith({
    Color? ink,
    Color? paper,
    Color? surface,
    Color? muted,
    Color? rule,
    Color? accent,
    Color? error,
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
      error: error ?? this.error,
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
      error: Color.lerp(error, other.error, t)!,
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
  /// M3 shape scale: compact for dense rows, large for surfaces
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;

  // Legacy aliases kept so call sites migrate without a half-patched theme.
  static const row = xs;
  static const card = md;
}

abstract final class Motion {
  static const short = Duration(milliseconds: 150);
  static const medium = Duration(milliseconds: 200);
  static const long = Duration(milliseconds: 300);

  static bool reduced(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context);

  static Duration duration(BuildContext context, Duration value) =>
      reduced(context) ? Duration.zero : value;
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
  final scheme = ColorScheme.fromSeed(
    seedColor: DrovesColors.seed,
    brightness: brightness,
  ).copyWith(
    surface: c.surface,
    primary: c.accent,
    onPrimary: brightness == Brightness.dark
        ? const Color(0xFF3A1A0B)
        : Colors.white,
    onSurface: c.ink,
    onSurfaceVariant: c.muted,
    outlineVariant: c.rule,
    secondary: c.accent,
    onSecondary: brightness == Brightness.dark
        ? const Color(0xFF3A1A0B)
        : Colors.white,
    error: c.error,
  );
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    textTheme: _m3TextTheme(brightness),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: c.accent,
      selectionColor: c.accent.withValues(alpha: 0.28),
      selectionHandleColor: c.accent,
    ),
  );
  final shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(Radii.md),
  );
  return base.copyWith(
    scaffoldBackgroundColor: c.paper,
    extensions: [c],
    dividerTheme: DividerThemeData(color: c.rule, thickness: 1, space: 1),
    appBarTheme: AppBarTheme(
      backgroundColor: c.paper,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleSpacing: Space.md,
      toolbarHeight: 64,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: c.paper,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      indicatorColor: c.accent.withValues(alpha: 0.16),
      iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
        color: states.contains(WidgetState.selected) ? c.accent : c.muted,
      )),
      labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
        fontFamily: 'PlexMono',
        fontSize: 11,
        color: states.contains(WidgetState.selected) ? c.accent : c.muted,
        fontWeight: states.contains(WidgetState.selected)
            ? FontWeight.w600
            : FontWeight.w500,
      )),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: c.paper,
      elevation: 0,
      indicatorColor: c.accent.withValues(alpha: 0.16),
      selectedIconTheme: IconThemeData(color: c.accent),
      unselectedIconTheme: IconThemeData(color: c.muted),
      selectedLabelTextStyle: monoStyleFor(
        brightness,
        size: 11,
        color: c.accent,
      ),
      unselectedLabelTextStyle: monoStyleFor(brightness, size: 11, color: c.muted),
      labelType: NavigationRailLabelType.all,
    ),
    cardTheme: CardThemeData(
      color: c.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: shape,
      margin: EdgeInsets.zero,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 3,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(Radii.lg)),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 2,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.lg)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: c.surface,
      contentTextStyle: monoStyleFor(brightness, size: 12, color: c.ink),
      actionTextColor: c.accent,
      behavior: SnackBarBehavior.floating,
      shape: shape,
    ),
    chipTheme: ChipThemeData(
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(Radii.sm)),
      ),
      labelStyle: monoStyleFor(brightness, size: 11, color: c.ink),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(Radii.sm)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(Radii.sm)),
        borderSide: BorderSide(color: c.accent, width: 2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.accent,
        foregroundColor: scheme.onPrimary,
        shape: shape,
        minimumSize: const Size(64, 48),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.accent,
        side: BorderSide(color: c.rule),
        shape: shape,
        minimumSize: const Size(64, 48),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: c.accent),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: c.ink),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? scheme.onPrimary : c.muted),
      trackColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected)
              ? c.accent
              : c.rule.withValues(alpha: 0.7)),
    ),
    pageTransitionsTheme: PageTransitionsTheme(
      builders: {
        for (final platform in TargetPlatform.values)
          platform: const _M3PageTransitionsBuilder(),
      },
    ),
  );
}

class _M3PageTransitionsBuilder extends PageTransitionsBuilder {
  const _M3PageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    ModalRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    if (reduced) return child;
    return FadeTransition(
      opacity: CurvedAnimation(
        parent: animation,
        curve: Curves.easeOut,
        reverseCurve: Curves.easeIn,
      ),
      child: child,
    );
  }
}

TextTheme _m3TextTheme(Brightness brightness) {
  final display = ThemeData(brightness: brightness).textTheme;
  return display.copyWith(
    displayLarge: display.displayLarge?.copyWith(fontFamily: 'Fraunces'),
    displayMedium: display.displayMedium?.copyWith(fontFamily: 'Fraunces'),
    displaySmall: display.displaySmall?.copyWith(fontFamily: 'Fraunces'),
    headlineLarge: display.headlineLarge?.copyWith(fontFamily: 'Fraunces'),
    headlineMedium: display.headlineMedium?.copyWith(fontFamily: 'Fraunces'),
    headlineSmall: display.headlineSmall?.copyWith(fontFamily: 'Fraunces'),
    titleLarge: display.titleLarge?.copyWith(fontFamily: 'Fraunces'),
    titleMedium: display.titleMedium?.copyWith(fontFamily: 'Fraunces'),
    titleSmall: display.titleSmall?.copyWith(fontFamily: 'Fraunces'),
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
  return monoStyleFor(
    Theme.of(context).brightness,
    size: size,
    color: color ?? context.colors.ink,
    weight: weight,
  );
}

TextStyle monoStyleFor(
  Brightness brightness, {
  double size = 12,
  required Color color,
  FontWeight weight = FontWeight.w400,
}) {
  return TextStyle(
    fontFamily: 'PlexMono',
    fontFamilyFallback: const ['JetBrainsMonoNerd', 'NotoColorEmoji'],
    fontSize: size,
    height: 1.45,
    fontWeight: weight,
    color: color,
  );
}
