import 'package:flutter/material.dart';

/// Semantic colour tokens of ZCode's design system (DESIGN.md), valued from
/// the `.theme-zai-light` / `.theme-zai-dark` blocks of `packages/ui/src/styles.css`.
@immutable
class ZTokens extends ThemeExtension<ZTokens> {
  const ZTokens({
    required this.background,
    required this.panel,
    required this.sidebar,
    required this.surface,
    required this.surfaceHover,
    required this.card,
    required this.popover,
    required this.input,
    required this.menuHover,
    required this.primary,
    required this.primaryForeground,
    required this.secondary,
    required this.border,
    required this.borderHover,
    required this.hover,
    required this.selected,
    required this.foreground,
    required this.foregroundSubtle,
    required this.foregroundSubtlest,
    required this.success,
    required this.warning,
    required this.destructive,
    required this.confirmSurface,
    required this.confirmForeground,
    required this.accent,
    required this.link,
    required this.tag,
    required this.codeBackground,
    required this.usageChart,
    required this.usageChart3,
  });

  final Color background;
  final Color panel;
  final Color sidebar;
  final Color surface;
  final Color surfaceHover;
  final Color card;
  final Color popover;
  final Color input;
  final Color menuHover;
  final Color primary;
  final Color primaryForeground;
  final Color secondary;
  final Color border;
  final Color borderHover;
  final Color hover;
  final Color selected;
  final Color foreground;
  final Color foregroundSubtle;
  final Color foregroundSubtlest;
  final Color success;
  final Color warning;
  final Color destructive;
  final Color confirmSurface;
  final Color confirmForeground;
  final Color accent;
  final Color link;
  final Color tag;
  final Color codeBackground;

  /// `--color-usage-chart-1`: the context-usage bar.
  final Color usageChart;

  /// `--color-usage-chart-3` (tool-call quota); chart-2 and chart-5 equal
  /// [success] and [warning].
  final Color usageChart3;

  static const _neutral300 = Color(0xFFD4D4D4);
  static const _neutral800 = Color(0xFF262626);

  static const dark = ZTokens(
    background: Color(0xFF161616),
    panel: Color(0xFF202020),
    sidebar: Color(0xFF1B1B1B),
    surface: Color(0x0DFFFFFF),
    surfaceHover: Color(0x1AFFFFFF),
    card: Color(0xFF2B2B2B),
    popover: Color(0xFF2B2B2B),
    input: Color(0xFF2B2B2B),
    menuHover: Color(0xFF363636),
    primary: Color(0xFFFFFFFF),
    primaryForeground: Color(0xFF000000),
    secondary: Color(0xFF363636),
    border: Color(0x1AFFFFFF),
    borderHover: Color(0x26FFFFFF),
    hover: Color(0x0DFFFFFF),
    selected: Color(0x1AFFFFFF),
    foreground: _neutral300,
    foregroundSubtle: Color(0x99D4D4D4),
    foregroundSubtlest: Color(0x4DD4D4D4),
    success: Color(0xFF46BF72),
    warning: Color(0xFFFF8A30),
    destructive: Color(0xFFFF5C5C),
    confirmSurface: Color(0x2946BF72),
    confirmForeground: Color(0xFF87D9A4),
    accent: Color(0xFF001D3D),
    link: Color(0xFF80BEFF),
    tag: Color(0xFF363636),
    codeBackground: Color(0xFF1E1E1E),
    usageChart: Color(0xFF4099FF),
    usageChart3: Color(0xFF7B5CE5),
  );

  static const light = ZTokens(
    background: Color(0xFFF8F8F8),
    panel: Color(0xFFFFFFFF),
    sidebar: Color(0xFFF0F0F0),
    surface: Color(0x080D0D0D),
    surfaceHover: Color(0x0D0D0D0D),
    card: Color(0xFFFFFFFF),
    popover: Color(0xFFFFFFFF),
    input: Color(0xFFFFFFFF),
    menuHover: Color(0xFFF0F0F0),
    primary: Color(0xFF000000),
    primaryForeground: Color(0xFFFFFFFF),
    secondary: Color(0xFFE6E6E6),
    border: Color(0x1A0D0D0D),
    borderHover: Color(0x260D0D0D),
    hover: Color(0x0D0D0D0D),
    selected: Color(0x0D0D0D0D),
    foreground: _neutral800,
    foregroundSubtle: Color(0x99262626),
    foregroundSubtlest: Color(0x66262626),
    success: Color(0xFF1E8A3E),
    warning: Color(0xFFE07B00),
    destructive: Color(0xFFE03131),
    confirmSurface: Color(0xFFEAF7EE),
    confirmForeground: Color(0xFF166B32),
    accent: Color(0xFFEBF4FF),
    link: Color(0xFF0066DD),
    tag: Color(0xFFE6E6E6),
    codeBackground: Color(0xFFF3F3F3),
    usageChart: Color(0xFF0B7FFF),
    usageChart3: Color(0xFF9E77ED),
  );

  @override
  ZTokens copyWith() => this;

  @override
  ZTokens lerp(ThemeExtension<ZTokens>? other, double t) =>
      other is ZTokens && t > 0.5 ? other : this;
}

/// `text-ui-*` scale (base 14px) and radii from DESIGN.md.
abstract final class ZText {
  static const xl = 18.0;
  static const lg = 16.0;
  static const base = 14.0;
  static const caption = 13.0;
  static const sm = 12.0;
  static const xs = 10.0;
}

abstract final class ZRadius {
  static const sm = 4.0;
  static const md = 6.0;
  static const lg = 8.0;
  static const xl = 12.0;
  static const x2l = 16.0;
}

const zMonoFamily = 'monospace';
const zMonoFallback = ['Menlo', 'Consolas', 'Roboto Mono', 'DejaVu Sans Mono'];

extension ZThemeContext on BuildContext {
  ZTokens get z => Theme.of(this).extension<ZTokens>()!;
}

ThemeData buildZTheme(Brightness brightness) {
  final z = brightness == Brightness.dark ? ZTokens.dark : ZTokens.light;
  final base = ThemeData(
    brightness: brightness,
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: z.primary,
      brightness: brightness,
    ).copyWith(
      primary: z.primary,
      onPrimary: z.primaryForeground,
      surface: z.background,
      onSurface: z.foreground,
      error: z.destructive,
      outline: z.border,
      outlineVariant: z.border,
      surfaceContainerHighest: z.card,
    ),
  );
  final text = base.textTheme.apply(bodyColor: z.foreground, displayColor: z.foreground);
  return base.copyWith(
    extensions: [z],
    scaffoldBackgroundColor: z.background,
    canvasColor: z.background,
    dividerColor: z.border,
    splashFactory: InkRipple.splashFactory,
    highlightColor: z.hover,
    splashColor: z.hover,
    hoverColor: z.hover,
    textTheme: text.copyWith(
      bodyLarge: text.bodyLarge?.copyWith(fontSize: ZText.base, height: 1.6),
      bodyMedium: text.bodyMedium?.copyWith(fontSize: ZText.base, height: 1.5),
      bodySmall: text.bodySmall?.copyWith(fontSize: ZText.sm, color: z.foregroundSubtle),
      titleMedium: text.titleMedium?.copyWith(fontSize: ZText.base, fontWeight: FontWeight.w600),
      titleLarge: text.titleLarge?.copyWith(fontSize: ZText.lg, fontWeight: FontWeight.w600),
      labelLarge: text.labelLarge?.copyWith(fontSize: ZText.base),
    ),
    iconTheme: IconThemeData(color: z.foregroundSubtle, size: 16),
    appBarTheme: AppBarTheme(
      backgroundColor: z.panel,
      foregroundColor: z.foreground,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(
          fontSize: ZText.base, fontWeight: FontWeight.w600, color: z.foreground),
      iconTheme: IconThemeData(color: z.foregroundSubtle, size: 18),
    ),
    drawerTheme: DrawerThemeData(backgroundColor: z.sidebar, shape: const RoundedRectangleBorder()),
    dialogTheme: DialogThemeData(
      backgroundColor: z.popover,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ZRadius.x2l),
        side: BorderSide(color: z.border),
      ),
      titleTextStyle: TextStyle(fontSize: ZText.lg, fontWeight: FontWeight.w600, color: z.foreground),
      contentTextStyle: TextStyle(fontSize: ZText.base, color: z.foregroundSubtle, height: 1.5),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: z.popover,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: z.popover,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(ZRadius.x2l))),
      showDragHandle: true,
      dragHandleColor: z.foregroundSubtlest,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: z.popover,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ZRadius.lg),
        side: BorderSide(color: z.border),
      ),
      textStyle: TextStyle(fontSize: ZText.base, color: z.foreground),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: z.card,
      contentTextStyle: TextStyle(color: z.foreground, fontSize: ZText.base),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ZRadius.x2l),
        side: BorderSide(color: z.border),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: z.input,
      hintStyle: TextStyle(color: z.foregroundSubtlest, fontSize: ZText.base),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ZRadius.lg),
        borderSide: BorderSide(color: z.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ZRadius.lg),
        borderSide: BorderSide(color: z.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ZRadius.lg),
        borderSide: BorderSide(color: z.borderHover),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: z.primary,
        foregroundColor: z.primaryForeground,
        minimumSize: const Size(64, 36),
        textStyle: const TextStyle(fontSize: ZText.base, fontWeight: FontWeight.w500),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ZRadius.lg)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: z.foreground,
        side: BorderSide(color: z.border),
        minimumSize: const Size(64, 36),
        textStyle: const TextStyle(fontSize: ZText.base, fontWeight: FontWeight.w500),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ZRadius.lg)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: z.foreground,
        textStyle: const TextStyle(fontSize: ZText.base, fontWeight: FontWeight.w500),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ZRadius.lg)),
      ),
    ),
    listTileTheme: ListTileThemeData(
      dense: true,
      iconColor: z.foregroundSubtle,
      textColor: z.foreground,
      titleTextStyle: TextStyle(fontSize: ZText.base, color: z.foreground),
      subtitleTextStyle: TextStyle(fontSize: ZText.sm, color: z.foregroundSubtle),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ZRadius.lg)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? z.primaryForeground : z.foregroundSubtle),
      trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? z.primary : z.secondary),
      trackOutlineColor: WidgetStatePropertyAll(z.border),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: z.foregroundSubtle),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(z.foregroundSubtlest),
      thickness: const WidgetStatePropertyAll(3),
    ),
  );
}
