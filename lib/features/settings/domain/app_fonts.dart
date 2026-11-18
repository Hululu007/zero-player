/// The handwriting face is bundled; the other choice uses the device font.
const appFontLabels = {'xiaolai': '小赖 · 柔和手写（默认）', 'system': '系统字体'};

// Existing settings/backups may still name a removed bundled face.
const _retiredAppFonts = {'notoSans', 'notoSerif'};
bool validAppFont(Object? key) =>
    appFontLabels.containsKey(key) || _retiredAppFonts.contains(key);
String appFontPreference(Object? key) => appFontLabels.containsKey(key)
    ? key as String
    : _retiredAppFonts.contains(key)
    ? 'system'
    : 'xiaolai';

String? appFontFamily(String key) => switch (key) {
  'xiaolai' => 'Xiaolai',
  _ => null,
};
