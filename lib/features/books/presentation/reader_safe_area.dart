import 'dart:math' as math;
import 'dart:ui' show DisplayFeatureType;

import 'package:flutter/material.dart';

import 'reader_style.dart';

/// System bars may be hidden while a physical cutout still occupies pixels.
/// Retain viewPadding and reported cutouts, then add the user's extra spacing.
class ReaderSafeArea extends StatelessWidget {
  const ReaderSafeArea({
    super.key,
    required this.preferences,
    required this.child,
    this.forceTop = false,
  });
  final ReaderPreferences preferences;
  final Widget child;
  final bool forceTop;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    var cutout = 0.0;
    if (preferences.protectCutout) {
      cutout = media.viewPadding.top;
      for (final feature in media.displayFeatures) {
        if (feature.type == DisplayFeatureType.cutout &&
            feature.bounds.top <= 0) {
          cutout = math.max(cutout, feature.bounds.bottom);
        }
      }
    }
    return SafeArea(
      top: forceTop || !preferences.immersive || preferences.protectCutout,
      minimum: EdgeInsets.only(top: cutout),
      maintainBottomViewPadding: true,
      child: Padding(
        padding: EdgeInsets.only(top: preferences.topInset),
        child: child,
      ),
    );
  }
}
