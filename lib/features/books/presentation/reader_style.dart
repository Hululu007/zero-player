import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../data/reader_fonts.dart';
import 'reader_font_picker.dart';

enum ReaderTurnMode {
  slide('横向滑动', '左右滑动或点按两侧翻页'),
  curl('仿真翻页', '从左右滑动可拖动纸页，也可点按翻页'),
  vertical('纵向分页', '上下滑动或点按上下区域翻页'),
  scroll('连续滚动', '上下滚动，到章首或章末可继续滑动切章');

  const ReaderTurnMode(this.label, this.hint);
  final String label, hint;

  bool get horizontal => this == slide || this == curl;
}

enum ReaderPaper {
  system('跟随系统'),
  white('白纸'),
  warm('暖纸'),
  green('护眼'),
  mist('雾蓝'),
  dark('夜间'),
  ink('墨黑');

  const ReaderPaper(this.label);
  final String label;

  ReaderPalette palette(ColorScheme colors) => switch (this) {
    system => ReaderPalette(colors.surface, colors.onSurface, colors.primary),
    white => const ReaderPalette(
      Color(0xfffcfcf8),
      Color(0xff262621),
      Color(0xff445942),
    ),
    warm => const ReaderPalette(
      Color(0xfff5ebd5),
      Color(0xff392e24),
      Color(0xff7b4830),
    ),
    green => const ReaderPalette(
      Color(0xffdce8d6),
      Color(0xff253326),
      Color(0xff36563e),
    ),
    mist => const ReaderPalette(
      Color(0xffe6eef0),
      Color(0xff253841),
      Color(0xff365d70),
    ),
    dark => const ReaderPalette(
      Color(0xff1b2027),
      Color(0xffe7e0d4),
      Color(0xffd9b993),
    ),
    ink => const ReaderPalette(
      Color(0xff101113),
      Color(0xffdcd9d2),
      Color(0xffbbd4cc),
    ),
  };
}

final class ReaderPalette {
  const ReaderPalette(this.paper, this.ink, this.accent);
  final Color paper, ink, accent;
  Brightness get brightness => ThemeData.estimateBrightnessForColor(paper);
}

final class ReaderPreferences {
  const ReaderPreferences({
    this.mode = ReaderTurnMode.slide,
    this.paper = ReaderPaper.system,
    this.family = 'system',
    this.fontSize = 21,
    this.lineHeight = 1.8,
    this.letterSpacing = 0,
    this.margin = 22,
    this.bold = false,
    this.justify = false,
    this.texture = true,
    this.animate = true,
    this.automatic = true,
    this.status = true,
    this.immersive = true,
    this.protectCutout = true,
    this.topInset = 0,
    this.preloadChapters = 2,
    this.preloadRefillAt = 1,
    this.preloadUnmeteredOnly = true,
    this.autoEnabled = false,
    this.autoSeconds = 10,
    this.scrollSpeed = 30,
  });

  factory ReaderPreferences.fromJson(Map data) => ReaderPreferences(
    mode:
        ReaderTurnMode.values
            .where((mode) => mode.name == data['mode'])
            .firstOrNull ??
        (data['paged'] == false ? ReaderTurnMode.scroll : ReaderTurnMode.slide),
    paper:
        ReaderPaper.values
            .where((paper) => paper.name == data['paper'])
            .firstOrNull ??
        ReaderPaper.system,
    family: validReaderFontFamily(data['family'])
        ? data['family'] as String
        : 'system',
    fontSize: _number(data['font'], 21, 12, 44),
    lineHeight: _number(data['line'], 1.8, 1.2, 2.6),
    letterSpacing: _number(data['spacing'], 0, 0, 2),
    margin: _number(data['margin'], 22, 12, 48),
    bold: data['bold'] == true,
    justify: data['justify'] == true,
    texture: data['texture'] != false,
    animate: data['animate'] != false,
    automatic: data['automatic'] != false,
    status: data['status'] != false,
    immersive: data['immersive'] != false,
    protectCutout: data['protectCutout'] != false,
    topInset: _number(data['topInset'], 0, 0, 80),
    preloadChapters: _number(data['preloadChapters'], 2, 0, 5).round(),
    preloadRefillAt: _number(data['preloadRefillAt'], 1, 0, 4).round(),
    preloadUnmeteredOnly: data['preloadUnmeteredOnly'] != false,
    autoEnabled: data['autoEnabled'] == true,
    autoSeconds: _number(data['autoSeconds'], 10, 2, 120),
    scrollSpeed: _number(data['scrollSpeed'], 30, 5, 150),
  );

  final ReaderTurnMode mode;
  final ReaderPaper paper;
  final String family;
  final double fontSize, lineHeight, letterSpacing, margin;
  final bool texture, animate, automatic, status, immersive, autoEnabled;
  final bool bold, justify, protectCutout, preloadUnmeteredOnly;
  final double topInset;
  final int preloadChapters, preloadRefillAt;
  final double autoSeconds, scrollSpeed;

  /// Body text style for this preference set. Headings add their own weight in
  /// the pagination layer, so bold here only lifts the reading weight.
  TextStyle get bodyStyle => TextStyle(
    inherit: false,
    fontFamily: readerFontFamily(family),
    fontSize: fontSize,
    height: lineHeight,
    letterSpacing: letterSpacing,
    fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
  );

  ReaderPreferences copyWith({
    ReaderTurnMode? mode,
    ReaderPaper? paper,
    String? family,
    double? fontSize,
    double? lineHeight,
    double? letterSpacing,
    double? margin,
    bool? bold,
    bool? justify,
    bool? texture,
    bool? animate,
    bool? automatic,
    bool? status,
    bool? immersive,
    bool? protectCutout,
    double? topInset,
    int? preloadChapters,
    int? preloadRefillAt,
    bool? preloadUnmeteredOnly,
    bool? autoEnabled,
    double? autoSeconds,
    double? scrollSpeed,
  }) => ReaderPreferences(
    mode: mode ?? this.mode,
    paper: paper ?? this.paper,
    family: family ?? this.family,
    fontSize: fontSize ?? this.fontSize,
    lineHeight: lineHeight ?? this.lineHeight,
    letterSpacing: letterSpacing ?? this.letterSpacing,
    margin: margin ?? this.margin,
    bold: bold ?? this.bold,
    justify: justify ?? this.justify,
    texture: texture ?? this.texture,
    animate: animate ?? this.animate,
    automatic: automatic ?? this.automatic,
    status: status ?? this.status,
    immersive: immersive ?? this.immersive,
    protectCutout: protectCutout ?? this.protectCutout,
    topInset: topInset ?? this.topInset,
    preloadChapters: preloadChapters ?? this.preloadChapters,
    preloadRefillAt: preloadRefillAt ?? this.preloadRefillAt,
    preloadUnmeteredOnly: preloadUnmeteredOnly ?? this.preloadUnmeteredOnly,
    autoEnabled: autoEnabled ?? this.autoEnabled,
    autoSeconds: autoSeconds ?? this.autoSeconds,
    scrollSpeed: scrollSpeed ?? this.scrollSpeed,
  );

  Map<String, Object> toJson() => {
    'mode': mode.name,
    'paper': paper.name,
    'family': family,
    'font': fontSize,
    'line': lineHeight,
    'spacing': letterSpacing,
    'margin': margin,
    'bold': bold,
    'justify': justify,
    'texture': texture,
    'animate': animate,
    'automatic': automatic,
    'status': status,
    'immersive': immersive,
    'protectCutout': protectCutout,
    'topInset': topInset,
    'preloadChapters': preloadChapters,
    'preloadRefillAt': preloadRefillAt,
    'preloadUnmeteredOnly': preloadUnmeteredOnly,
    'autoEnabled': autoEnabled,
    'autoSeconds': autoSeconds,
    'scrollSpeed': scrollSpeed,
  };
}

const _fonts = readerBundledFonts;

double _number(Object? value, double fallback, double min, double max) =>
    value is num && value.isFinite
    ? value.toDouble().clamp(min, max)
    : fallback;

class ReaderPaperSurface extends StatelessWidget {
  const ReaderPaperSurface({
    super.key,
    required this.palette,
    required this.texture,
  });
  final ReaderPalette palette;
  final bool texture;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      painter: _PaperPainter(palette.paper, palette.ink, texture),
      child: const SizedBox.expand(),
    ),
  );
}

final class _PaperPainter extends CustomPainter {
  const _PaperPainter(this.paper, this.ink, this.texture);
  final Color paper, ink;
  final bool texture;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = paper);
    if (!texture) return;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: [
            ink.withValues(alpha: .04),
            Colors.transparent,
            Colors.transparent,
            ink.withValues(alpha: .035),
          ],
          stops: const [0, .14, .88, 1],
        ).createShader(rect),
    );
    final random = math.Random(32);
    final fiber = Paint()
      ..color = ink.withValues(alpha: .08)
      ..strokeWidth = .55;
    final count = (size.width * size.height / 330).round().clamp(0, 2400);
    for (var index = 0; index < count; index++) {
      final start = Offset(
        random.nextDouble() * size.width,
        random.nextDouble() * size.height,
      );
      canvas.drawLine(
        start,
        start +
            Offset(.7 + random.nextDouble() * 1.9, random.nextDouble() - .5),
        fiber,
      );
    }
  }

  @override
  bool shouldRepaint(_PaperPainter oldDelegate) =>
      oldDelegate.paper != paper ||
      oldDelegate.ink != ink ||
      oldDelegate.texture != texture;
}

Future<void> showReaderSettings(
  BuildContext context,
  ReaderPreferences initial,
  ValueChanged<ReaderPreferences> onChange, {
  bool rich = false,
  bool pdf = false,
  ReaderFontStore? fontStore,
  VoidCallback? onCleanupRules,
  VoidCallback? onClearCache,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (context) {
    var settings = initial;
    return StatefulBuilder(
      builder: (context, update) {
        void change(ReaderPreferences next) {
          update(() => settings = next);
          onChange(next);
        }

        return FractionallySizedBox(
          heightFactor: .81,
          child: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              children: [
                Text('阅读样式', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 14),
                if (!pdf) _turnModeSettings(settings, change),
                ..._automationSettings(settings, change, pdf: pdf),
                const SizedBox(height: 16),
                if (!pdf) ..._paperSettings(context, settings, change),
                if (!pdf) ..._typography(context, settings, change, fontStore),
                if (!pdf)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('翻页动画'),
                    value: settings.animate,
                    onChanged: (value) =>
                        change(settings.copyWith(animate: value)),
                  ),
                if (!rich)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('显示页码与时间'),
                    value: settings.status,
                    onChanged: (value) =>
                        change(settings.copyWith(status: value)),
                  ),
                if (!rich)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('正文失败时自动换源'),
                    value: settings.automatic,
                    onChanged: (value) =>
                        change(settings.copyWith(automatic: value)),
                  ),
                ..._insetSettings(settings, change),
                if (!rich) ..._loadingSettings(settings, change),
                if (onCleanupRules != null)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('阅读净化规则'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: onCleanupRules,
                  ),
                if (onClearCache != null)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('清除本书临时阅读缓存'),
                    subtitle: const Text('保留已下载的离线章节'),
                    onTap: onClearCache,
                  ),
              ],
            ),
          ),
        );
      },
    );
  },
);

/// Compact style sheet for phones: presets, font size, alignment and weight in
/// one short sheet, with a link to the full settings when more is needed.
Future<bool?> showReaderQuickStyle(
  BuildContext context,
  ReaderPreferences initial,
  ValueChanged<ReaderPreferences> onChange,
) => showModalBottomSheet<bool>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (context) {
    var settings = initial;
    return StatefulBuilder(
      builder: (context, update) {
        void change(ReaderPreferences next) {
          update(() => settings = next);
          onChange(next);
        }

        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '字号与排版',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      child: const Text('更多样式'),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final preset in _typePresets)
                      ChoiceChip(
                        label: Text(preset.label),
                        selected: preset.matches(settings),
                        onSelected: (_) => change(preset.apply(settings)),
                      ),
                  ],
                ),
                _fontSizeSlider(settings, change),
                _lineHeightSlider(settings, change),
                _StyleSlider(
                  label: '页边距',
                  value: settings.margin,
                  min: 12,
                  max: 48,
                  divisions: 18,
                  onChanged: (value) =>
                      change(settings.copyWith(margin: value)),
                ),
                Wrap(
                  spacing: 7,
                  runSpacing: 6,
                  children: [
                    FilterChip(
                      label: const Text('两端对齐'),
                      selected: settings.justify,
                      onSelected: (value) =>
                          change(settings.copyWith(justify: value)),
                    ),
                    FilterChip(
                      label: const Text('加粗正文'),
                      selected: settings.bold,
                      onSelected: (value) =>
                          change(settings.copyWith(bold: value)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  },
);

List<Widget> _paperSettings(
  BuildContext context,
  ReaderPreferences settings,
  ValueChanged<ReaderPreferences> change,
) => [
  const Text('纸张'),
  Wrap(
    spacing: 7,
    children: [
      for (final paper in ReaderPaper.values)
        ChoiceChip(
          avatar: CircleAvatar(
            backgroundColor: paper.palette(Theme.of(context).colorScheme).paper,
          ),
          label: Text(paper.label),
          selected: settings.paper == paper,
          onSelected: (_) => change(settings.copyWith(paper: paper)),
        ),
    ],
  ),
  SwitchListTile(
    contentPadding: EdgeInsets.zero,
    title: const Text('纸面纹理'),
    value: settings.texture,
    onChanged: (value) => change(settings.copyWith(texture: value)),
  ),
];

Widget _turnModeSettings(
  ReaderPreferences settings,
  ValueChanged<ReaderPreferences> change,
) => Column(
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    const Text('翻页方式'),
    Wrap(
      spacing: 7,
      children: [
        for (final mode in ReaderTurnMode.values)
          ChoiceChip(
            label: Text(mode.label),
            selected: settings.mode == mode,
            onSelected: (_) => change(settings.copyWith(mode: mode)),
          ),
      ],
    ),
    Text(settings.mode.hint),
  ],
);

List<Widget> _typography(
  BuildContext context,
  ReaderPreferences settings,
  ValueChanged<ReaderPreferences> change,
  ReaderFontStore? fontStore,
) => [
  DropdownButtonFormField<String>(
    key: ValueKey(settings.family),
    initialValue: settings.family,
    decoration: const InputDecoration(labelText: '字体'),
    items: [
      if (!_fonts.containsKey(settings.family))
        DropdownMenuItem(
          value: settings.family,
          child: Text(readerFontLabel(settings.family)),
        ),
      for (final entry in _fonts.entries)
        DropdownMenuItem(
          value: entry.key,
          child: Text(
            entry.value,
            style: TextStyle(fontFamily: readerFontFamily(entry.key)),
          ),
        ),
    ],
    onChanged: (value) => change(settings.copyWith(family: value)),
  ),
  if (fontStore != null)
    ListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('更多字体：系统与开源下载'),
      subtitle: Text(readerFontLabel(settings.family)),
      trailing: const Icon(Icons.font_download_outlined),
      onTap: () async {
        final family = await showReaderFontPicker(
          context,
          fontStore,
          settings.family,
        );
        if (context.mounted && family != null) {
          change(settings.copyWith(family: family));
        }
      },
    ),
  const SizedBox(height: 10),
  Wrap(
    spacing: 6,
    runSpacing: 6,
    children: [
      for (final preset in _typePresets)
        ChoiceChip(
          label: Text(preset.label),
          selected: preset.matches(settings),
          onSelected: (_) => change(preset.apply(settings)),
        ),
    ],
  ),
  _fontSizeSlider(settings, change),
  _lineHeightSlider(settings, change),
  _StyleSlider(
    label: '字间距',
    value: settings.letterSpacing,
    min: 0,
    max: 2,
    divisions: 20,
    precision: 1,
    onChanged: (value) => change(settings.copyWith(letterSpacing: value)),
  ),
  _StyleSlider(
    label: '页边距',
    value: settings.margin,
    min: 12,
    max: 48,
    divisions: 18,
    onChanged: (value) => change(settings.copyWith(margin: value)),
  ),
  const SizedBox(height: 4),
  Wrap(
    spacing: 7,
    runSpacing: 6,
    children: [
      FilterChip(
        label: const Text('两端对齐'),
        selected: settings.justify,
        onSelected: (value) => change(settings.copyWith(justify: value)),
      ),
      FilterChip(
        label: const Text('加粗正文'),
        selected: settings.bold,
        onSelected: (value) => change(settings.copyWith(bold: value)),
      ),
    ],
  ),
];

/// Named typography presets keep the sheet usable on a phone: one tap sets a
/// coherent font size, line height and margin instead of three slider drags.
final class _ReaderPreset {
  const _ReaderPreset(this.label, this.fontSize, this.lineHeight, this.margin);
  final String label;
  final double fontSize, lineHeight, margin;

  bool matches(ReaderPreferences settings) =>
      settings.fontSize == fontSize &&
      (settings.lineHeight - lineHeight).abs() < .0001 &&
      settings.margin == margin;

  ReaderPreferences apply(ReaderPreferences settings) => settings.copyWith(
    fontSize: fontSize,
    lineHeight: lineHeight,
    margin: margin,
  );
}

const _typePresets = [
  _ReaderPreset('紧凑', 16, 1.6, 16),
  _ReaderPreset('标准', 21, 1.8, 22),
  _ReaderPreset('大字', 26, 1.9, 24),
  _ReaderPreset('特大', 32, 2.0, 26),
];

Widget _lineHeightSlider(
  ReaderPreferences settings,
  ValueChanged<ReaderPreferences> change,
) => _StyleSlider(
  label: '行距',
  value: settings.lineHeight,
  min: 1.2,
  max: 2.6,
  divisions: 28,
  precision: 2,
  onChanged: (value) =>
      change(settings.copyWith(lineHeight: (value * 100).round() / 100)),
);

Widget _fontSizeSlider(
  ReaderPreferences settings,
  ValueChanged<ReaderPreferences> change,
) {
  final size = settings.fontSize;
  return Row(
    children: [
      const Text('字号'),
      IconButton(
        tooltip: '减小字号',
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.text_decrease, size: 20),
        onPressed: size > 12
            ? () => change(settings.copyWith(fontSize: size - 1))
            : null,
      ),
      Expanded(
        child: Slider(
          value: size,
          min: 12,
          max: 44,
          divisions: 32,
          label: size.round().toString(),
          onChanged: (value) => change(settings.copyWith(fontSize: value)),
        ),
      ),
      IconButton(
        tooltip: '增大字号',
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.text_increase, size: 20),
        onPressed: size < 44
            ? () => change(settings.copyWith(fontSize: size + 1))
            : null,
      ),
      SizedBox(
        width: 24,
        child: Text(size.round().toString(), textAlign: TextAlign.center),
      ),
    ],
  );
}

final class _StyleSlider extends StatelessWidget {
  const _StyleSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    this.precision = 0,
  });
  final String label;
  final double value, min, max;
  final int divisions, precision;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Text(label),
      Expanded(
        child: Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          label: label,
          onChanged: onChanged,
        ),
      ),
      Text(value.toStringAsFixed(precision)),
    ],
  );
}

List<Widget> _automationSettings(
  ReaderPreferences settings,
  ValueChanged<ReaderPreferences> change, {
  required bool pdf,
}) => [
  SwitchListTile(
    contentPadding: EdgeInsets.zero,
    title: const Text('全屏沉浸阅读'),
    value: settings.immersive,
    onChanged: (value) => change(settings.copyWith(immersive: value)),
  ),
  SwitchListTile(
    contentPadding: EdgeInsets.zero,
    title: const Text('自动阅读'),
    value: settings.autoEnabled,
    onChanged: (value) => change(settings.copyWith(autoEnabled: value)),
  ),
  if (settings.autoEnabled)
    _StyleSlider(
      label: '翻页间隔（秒）',
      value: settings.autoSeconds,
      min: 2,
      max: 120,
      divisions: 118,
      onChanged: (v) => change(settings.copyWith(autoSeconds: v)),
    ),
  if (settings.autoEnabled && !pdf)
    _StyleSlider(
      label: '滚动速度',
      value: settings.scrollSpeed,
      min: 5,
      max: 150,
      divisions: 29,
      onChanged: (v) => change(settings.copyWith(scrollSpeed: v)),
    ),
];

List<Widget> _loadingSettings(
  ReaderPreferences settings,
  ValueChanged<ReaderPreferences> change,
) => [
  const Divider(),
  const Text('在线加载与缓存'),
  _StyleSlider(
    label: '预加载章数',
    value: settings.preloadChapters.toDouble(),
    min: 0,
    max: 5,
    divisions: 5,
    onChanged: (v) => change(settings.copyWith(preloadChapters: v.round())),
  ),
  if (settings.preloadChapters > 1)
    _StyleSlider(
      label: '剩余预加载章节数达到此值时补充',
      value: settings.preloadRefillAt
          .clamp(0, settings.preloadChapters - 1)
          .toDouble(),
      min: 0,
      max: (settings.preloadChapters - 1).toDouble(),
      divisions: settings.preloadChapters - 1,
      onChanged: (v) => change(settings.copyWith(preloadRefillAt: v.round())),
    ),
  SwitchListTile(
    contentPadding: EdgeInsets.zero,
    title: const Text('仅在非计费网络预加载'),
    value: settings.preloadUnmeteredOnly,
    onChanged: (v) => change(settings.copyWith(preloadUnmeteredOnly: v)),
  ),
  const Text('优先读取离线正文和阅读缓存。预加载会在阅读时补充后续章节，退到后台时暂停。阅读缓存最多 24 MiB。'),
];

List<Widget> _insetSettings(
  ReaderPreferences settings,
  ValueChanged<ReaderPreferences> change,
) => [
  SwitchListTile(
    contentPadding: EdgeInsets.zero,
    title: const Text('避让刘海与摄像头'),
    subtitle: const Text('沉浸阅读时保留系统安全区域'),
    value: settings.protectCutout,
    onChanged: (v) => change(settings.copyWith(protectCutout: v)),
  ),
  _StyleSlider(
    label: '顶部额外留白',
    value: settings.topInset,
    min: 0,
    max: 80,
    divisions: 40,
    onChanged: (v) => change(settings.copyWith(topInset: v)),
  ),
];
