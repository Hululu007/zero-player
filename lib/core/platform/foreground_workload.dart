import 'package:flutter/foundation.dart';

/// Defers optional discovery probes while reading or while the app is hidden.
/// Playback, downloads and synchronous content-policy checks do not use this gate.
final class ForegroundWorkload extends ChangeNotifier {
  static final instance = ForegroundWorkload();
  bool _foreground = true;
  int _readers = 0;
  bool get maintenanceAllowed => _foreground && _readers == 0;

  void setForeground(bool value) {
    if (_foreground == value) return;
    _foreground = value;
    notifyListeners();
  }

  VoidCallback beginReading() {
    _readers++;
    if (_readers == 1) notifyListeners();
    var released = false;
    return () {
      if (released) return;
      released = true;
      _readers--;
      if (_readers == 0) notifyListeners();
    };
  }
}
