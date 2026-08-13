import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../services/session_service.dart';

Future<void> _showCodeDialog(BuildContext context) async {
  final l10n = AppLocalizations.of(context);
  final controller = TextEditingController();
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l10n.homeCodeDialogTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l10n.homeCodeDialogBody,
            style: const TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: controller,
            autofocus: true,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 24,
              letterSpacing: 4,
            ),
            decoration: InputDecoration(
              hintText: l10n.homeCodeDialogHint,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text.trim()),
          child: Text(l10n.commonJoin),
        ),
      ],
    ),
  );
  controller.dispose();
  if (result == null || result.isEmpty || !context.mounted) return;

  // Navigate to join screen with the code pre-filled
  final session = await context.read<SessionService>().joinRoom(result);
  if (context.mounted && session != null) {
    Navigator.pushReplacementNamed(context, '/session');
  } else if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          context.read<SessionService>().error ?? l10n.homeJoinFailed,
        ),
      ),
    );
  }
}

/// Home is a dashboard, not a list. Every destination the app offers — the
/// quick translator, both ways into a session, the messenger, contacts, app
/// sharing and the history — is one tile on a single grid that is measured
/// against the height the screen actually offers, so a phone shows all of
/// them at once. Scrolling only kicks in when a tile can no longer be drawn
/// legibly (split screen, very small windows, very large system fonts).
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = context.watch<ThemeProvider>();
    return Scaffold(
      appBar: AppBar(
        title: const Row(children: [
          _SnailLogo(size: 30),
          SizedBox(width: 8),
          Text('Snail', style: TextStyle(fontWeight: FontWeight.w800))
        ]),
        actions: [
          IconButton(
              onPressed: theme.toggle,
              icon: Icon(theme.isDark
                  ? Icons.light_mode_outlined
                  : Icons.dark_mode_outlined)),
          IconButton(
              tooltip: l10n.commonSettings,
              onPressed: () => Navigator.pushNamed(context, '/settings'),
              icon: const Icon(Icons.tune_rounded)),
        ],
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(builder: (context, constraints) {
          final metrics = _GridMetrics.resolve(context, constraints);
          final board = Center(
            child: SizedBox(
              width: metrics.contentWidth,
              child: _Dashboard(metrics: metrics),
            ),
          );
          final padding = EdgeInsets.symmetric(
              horizontal: metrics.padH, vertical: metrics.padV);
          // The emergency case the grid cannot solve by shrinking: give the
          // very same board a scroll view instead of squeezing tiles below a
          // readable size.
          return metrics.scrolls
              ? SingleChildScrollView(padding: padding, child: board)
              : Padding(padding: padding, child: board);
        }),
      ),
    );
  }
}

/// One way to arrange the eight cells. Every shape fills its grid exactly —
/// `heroSpan + 6 single tiles + lastSpan == columns * rows` — so a row is
/// never left with a hole the way the old five-item quick-access grid was.
class _GridShape {
  const _GridShape({
    required this.columns,
    required this.rows,
    required this.heroSpan,
    required this.lastSpan,
  });

  final int columns;
  final int rows;
  final int heroSpan;
  final int lastSpan;

  double gap() => columns >= 5 ? 10.0 : 12.0;

  /// Beyond this the grid stops stretching and centres instead, so tiles on a
  /// tablet stay tiles rather than becoming banners.
  double maxContentWidth() => switch (columns) {
        >= 5 => 980.0,
        3 => 760.0,
        _ => 620.0,
      };
}

/// Sizes for one dashboard layout, derived from the box the grid may use.
class _GridMetrics {
  const _GridMetrics({
    required this.columns,
    required this.heroSpan,
    required this.lastSpan,
    required this.contentWidth,
    required this.tileWidth,
    required this.tileHeight,
    required this.gap,
    required this.padH,
    required this.padV,
    required this.textScale,
    required this.scrolls,
  });

  final int columns;
  final int heroSpan;
  final int lastSpan;
  final double contentWidth;
  final double tileWidth;
  final double tileHeight;
  final double gap;
  final double padH;
  final double padV;
  final double textScale;

  /// True when the tiles hit their minimum readable height before they fit.
  final bool scrolls;

  /// Everything inside a tile is derived from this unit rather than from
  /// fixed values, so the same grid works from a 320 dp split-screen window
  /// up to a tablet. Dividing by the text scale keeps room for the label:
  /// the larger the system font, the smaller the decoration around it.
  double get _unit => tileHeight / math.max(1.0, textScale);

  double get iconBox => (_unit * .34).clamp(30.0, 48.0);
  double get iconSize => iconBox * .55;
  double get logoSize => (_unit * .36).clamp(30.0, 52.0);
  double get tilePadding => (_unit * .11).clamp(10.0, 16.0);
  double get innerGap => (_unit * .06).clamp(6.0, 12.0);
  double get labelSize => (_unit * .11).clamp(11.5, 15.0);
  double get subtitleSize => (labelSize * .82).clamp(10.5, 13.0);
  double get heroTitleSize => (_unit * .17).clamp(16.5, 26.0);
  double get heroCtaSize => (_unit * .105).clamp(11.0, 14.0);
  double get heroBadgeSize => (_unit * .085).clamp(9.5, 12.0);
  double get radius => 20.0;

  /// The tagline is the first thing to go when the hero runs out of room.
  bool get heroShowsSubtitle => tileHeight >= 100 && textScale <= 1.3;

  /// Width of a cell spanning [span] columns, gaps included.
  double spanWidth(int span) => tileWidth * span + gap * (span - 1);

  /// Tall phone, short-and-narrow window, landscape or tablet — in that order
  /// of preference, the widest tiles first.
  static const _shapes = <_GridShape>[
    _GridShape(columns: 2, rows: 5, heroSpan: 2, lastSpan: 2),
    _GridShape(columns: 3, rows: 3, heroSpan: 2, lastSpan: 1),
    _GridShape(columns: 5, rows: 2, heroSpan: 3, lastSpan: 1),
  ];

  static const _padH = 16.0;

  static double _contentWidth(BoxConstraints c, _GridShape s) => math.min(
      math.max(c.maxWidth - _padH * 2, 0.0), s.maxContentWidth());

  static double _tileWidth(BoxConstraints c, _GridShape s) =>
      (_contentWidth(c, s) - s.gap() * (s.columns - 1)) / s.columns;

  static _GridMetrics resolve(BuildContext context, BoxConstraints c) {
    final scaler = MediaQuery.textScalerOf(context);
    final textScale = scaler.scale(12) / 12;
    final padV = (c.maxHeight * .018).clamp(8.0, 16.0);

    // Smallest tile that still holds the icon chip and two label lines at the
    // user's text scale: icon (30) + inner gap (6) + padding (2 × 10) plus the
    // two lines themselves — and wide enough that those lines are words
    // rather than ellipses.
    final minTile = math.max(72.0, 58 + scaler.scale(11.5) * 2.6);
    final minTileWidth = (96 + (textScale - 1) * 55).clamp(96.0, 210.0);

    // Pick the arrangement whose tiles come closest to a card-like shape
    // among those that fit the height the screen really has. Nothing here is
    // tied to a device or an orientation: a split-screen window and a phone
    // with a huge system font end up in the same branch by measurement.
    _GridShape? chosen;
    var bestScore = double.infinity;
    for (final shape in _shapes) {
      final width = _tileWidth(c, shape);
      final height =
          (c.maxHeight - padV * 2 - shape.gap() * (shape.rows - 1)) /
              shape.rows;
      if (width < minTileWidth || height < minTile) continue;
      final score = (width / height - 1.35).abs();
      if (score < bestScore) {
        bestScore = score;
        chosen = shape;
      }
    }

    // Nothing fits: this is the emergency the user allowed us to scroll for.
    // Take the fewest rows whose tiles are still wide enough to read.
    final scrolls = chosen == null;
    final shape = chosen ??
        _shapes.lastWhere((s) => _tileWidth(c, s) >= minTileWidth,
            orElse: () => _shapes.first);

    final gap = shape.gap();
    final tileWidth = _tileWidth(c, shape);
    final available = c.maxHeight - padV * 2 - gap * (shape.rows - 1);
    // Never taller than roughly a square, so large screens grow the tiles
    // without turning them into columns.
    final tileHeight = math.max(minTile,
        math.min(scrolls ? minTile : available / shape.rows, tileWidth * .95));

    return _GridMetrics(
      columns: shape.columns,
      heroSpan: shape.heroSpan,
      lastSpan: shape.lastSpan,
      contentWidth: _contentWidth(c, shape),
      tileWidth: tileWidth,
      tileHeight: tileHeight,
      gap: gap,
      padH: _padH,
      padV: padV,
      textScale: textScale,
      scrolls: scrolls,
    );
  }
}

/// One cell of the grid: a tile plus how many columns it covers.
class _Cell {
  const _Cell({required this.span, required this.child});
  final int span;
  final Widget child;
}

class _Dashboard extends StatelessWidget {
  const _Dashboard({required this.metrics});

  final _GridMetrics metrics;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final m = metrics;

    final cells = <_Cell>[
      _Cell(
        span: m.heroSpan,
        child: _HeroTile(
          metrics: m,
          onTap: () => Navigator.pushNamed(context, '/standalone'),
        ),
      ),
      _Cell(
        span: 1,
        child: _DashTile(
          metrics: m,
          icon: Icons.qr_code_rounded,
          label: l10n.homeStartSession,
          color: colors.primary,
          onTap: () => Navigator.pushNamed(context, '/qr-host'),
        ),
      ),
      _Cell(
        span: 1,
        child: _DashTile(
          metrics: m,
          icon: Icons.qr_code_scanner_rounded,
          label: l10n.commonJoin,
          color: colors.secondary,
          onTap: () => Navigator.pushNamed(context, '/join'),
        ),
      ),
      _Cell(
        span: 1,
        child: _DashTile(
          metrics: m,
          icon: Icons.keyboard_rounded,
          label: l10n.homeEnterCode,
          color: colors.tertiary,
          onTap: () => _showCodeDialog(context),
        ),
      ),
      _Cell(
        span: 1,
        child: _DashTile(
          metrics: m,
          icon: Icons.chat_bubble_rounded,
          label: l10n.homeMessenger,
          color: colors.primary,
          onTap: () => Navigator.pushNamed(context, '/chat'),
        ),
      ),
      _Cell(
        span: 1,
        child: _DashTile(
          metrics: m,
          icon: Icons.people_alt_rounded,
          label: l10n.homeContacts,
          color: colors.secondary,
          onTap: () => Navigator.pushNamed(context, '/contacts'),
        ),
      ),
      _Cell(
        span: 1,
        child: _DashTile(
          metrics: m,
          icon: Icons.share_rounded,
          label: l10n.homeShareAppShort,
          color: colors.tertiary,
          onTap: () => Navigator.pushNamed(context, '/app-share'),
        ),
      ),
      _Cell(
        span: m.lastSpan,
        // The bottom tile spans the full width in portrait, which leaves room
        // for the subtitle the old full-width history card used to carry.
        child: _DashTile(
          metrics: m,
          icon: Icons.history_rounded,
          label: l10n.historyTitle,
          subtitle: m.lastSpan > 1 ? l10n.homeHistorySubtitle : null,
          color: colors.primary,
          onTap: () => Navigator.pushNamed(context, '/history'),
        ),
      ),
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: _rows(cells),
    );
  }

  /// Packs the cells into rows of exactly [_GridMetrics.columns] columns. All
  /// cells but the last of a row get an explicit width; the last one takes
  /// the remainder so rounding can never overflow the row.
  List<Widget> _rows(List<_Cell> cells) {
    final m = metrics;
    final rows = <Widget>[];
    var index = 0;
    while (index < cells.length) {
      final row = <_Cell>[];
      var used = 0;
      while (index < cells.length && used + cells[index].span <= m.columns) {
        row.add(cells[index]);
        used += cells[index].span;
        index++;
      }
      if (rows.isNotEmpty) rows.add(SizedBox(height: m.gap));
      rows.add(SizedBox(
        height: m.tileHeight,
        child: Row(
          // Stretch, so a tile whose content is a row (the wide one at the
          // bottom) fills its cell instead of shrinking to its content.
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < row.length; i++) ...[
              if (i > 0) SizedBox(width: m.gap),
              if (i == row.length - 1)
                Expanded(child: row[i].child)
              else
                SizedBox(width: m.spanWidth(row[i].span), child: row[i].child),
            ],
          ],
        ),
      ));
    }
    return rows;
  }
}

/// The primary action: the standalone quick translator, set apart from the
/// other tiles by the brand gradient instead of by extra height.
class _HeroTile extends StatelessWidget {
  const _HeroTile({required this.metrics, required this.onTap});

  final _GridMetrics metrics;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final m = metrics;
    return Material(
      color: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      borderRadius: BorderRadius.circular(m.radius + 4),
      child: Ink(
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: [
            colors.primary,
            Color.alphaBlend(
                colors.secondary.withValues(alpha: .35), colors.primary)
          ]),
          borderRadius: BorderRadius.circular(m.radius + 4),
        ),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.all(m.tilePadding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: Row(
                    children: [
                      _SnailLogo(size: m.logoSize),
                      SizedBox(width: m.innerGap + 2),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Flexible(
                              child: Text(
                                l10n.homeQuickTranslator,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: m.heroTitleSize,
                                  fontWeight: FontWeight.w800,
                                  height: 1.15,
                                ),
                              ),
                            ),
                            if (m.heroShowsSubtitle)
                              Flexible(
                                child: Text(
                                  l10n.homeQuickTranslatorSubtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: m.subtitleSize,
                                    height: 1.2,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: m.innerGap),
                // The badge rides on the call-to-action line: it fills the
                // space to its right and leaves the title line its full width.
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              l10n.homeStartNow,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: m.heroCtaSize,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(Icons.arrow_forward_rounded,
                              color: Colors.white, size: m.heroCtaSize + 4),
                        ],
                      ),
                    ),
                    SizedBox(width: m.innerGap),
                    Container(
                      padding: EdgeInsets.symmetric(
                          horizontal: m.heroBadgeSize * .8,
                          vertical: m.heroBadgeSize * .35),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: .18),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        l10n.homeLiveBadge,
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: m.heroBadgeSize,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A single destination. Stacked icon over label by default; when the tile
/// spans more than one column it turns into a row and shows its subtitle.
class _DashTile extends StatelessWidget {
  const _DashTile({
    required this.metrics,
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.subtitle,
  });

  final _GridMetrics metrics;
  final IconData icon;
  final String label;
  final String? subtitle;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final m = metrics;
    final colors = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;

    final chip = Container(
      width: m.iconBox,
      height: m.iconBox,
      decoration: BoxDecoration(
        color: color.withValues(alpha: dark ? .20 : .13),
        borderRadius: BorderRadius.circular(m.iconBox * .32),
      ),
      child: Icon(icon, color: color, size: m.iconSize),
    );
    final title = Text(
      label,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontWeight: FontWeight.w700,
        fontSize: m.labelSize,
        height: 1.15,
        color: colors.onSurface,
      ),
    );

    return Material(
      color: Color.alphaBlend(
          color.withValues(alpha: dark ? .10 : .06), colors.surface),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(m.radius),
        side: BorderSide(color: color.withValues(alpha: dark ? .26 : .18)),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.all(m.tilePadding),
          child: subtitle == null
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    chip,
                    SizedBox(height: m.innerGap),
                    Flexible(child: title),
                  ],
                )
              : Row(
                  children: [
                    chip,
                    SizedBox(width: m.innerGap + 4),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Flexible(child: title),
                          Flexible(
                            child: Text(
                              subtitle!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: m.subtitleSize,
                                color: colors.onSurface.withValues(alpha: .65),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right_rounded,
                        size: m.iconSize,
                        color: colors.onSurface.withValues(alpha: .45)),
                  ],
                ),
        ),
      ),
    );
  }
}

class _SnailLogo extends StatelessWidget {
  const _SnailLogo({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(size * .24),
        child: Image.asset(
          'assets/branding/snail-logo.png',
          width: size,
          height: size,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.high,
        ),
      );
}
