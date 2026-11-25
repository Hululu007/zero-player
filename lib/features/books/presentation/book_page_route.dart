import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Touch devices can leave a book page from the leading edge, including when
/// the reader is hiding the Android system bars.
class BookPageRoute<T> extends MaterialPageRoute<T> {
  BookPageRoute({required super.builder, this.bothEdges = false});
  final bool bothEdges;

  @override
  Widget buildContent(BuildContext context) => BookBackGesture(
    bothEdges: bothEdges,
    onBack: () => unawaited(Navigator.maybePop(context)),
    child: super.buildContent(context),
  );
}

class BookBackGesture extends StatelessWidget {
  const BookBackGesture({
    super.key,
    required this.onBack,
    required this.child,
    this.bothEdges = true,
  });

  final VoidCallback onBack;
  final Widget child;
  final bool bothEdges;

  @override
  Widget build(BuildContext context) {
    if (Theme.of(context).platform != TargetPlatform.android) return child;
    final insets = MediaQuery.systemGestureInsetsOf(context);
    final leftToRight = Directionality.of(context) == TextDirection.ltr;
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        if (leftToRight || bothEdges)
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: math.max(24, insets.left + 8),
            child: _BookBackEdge(direction: 1, onBack: onBack),
          ),
        if (!leftToRight || bothEdges)
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: math.max(24, insets.right + 8),
            child: _BookBackEdge(direction: -1, onBack: onBack),
          ),
      ],
    );
  }
}

class _BookBackEdge extends StatefulWidget {
  const _BookBackEdge({required this.direction, required this.onBack});
  final int direction;
  final VoidCallback onBack;

  @override
  State<_BookBackEdge> createState() => _BookBackEdgeState();
}

class _BookBackEdgeState extends State<_BookBackEdge> {
  double _distance = 0;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    excludeFromSemantics: true,
    supportedDevices: const {PointerDeviceKind.touch, PointerDeviceKind.stylus},
    dragStartBehavior: DragStartBehavior.down,
    onHorizontalDragStart: (_) => _distance = 0,
    onHorizontalDragUpdate: (details) => _distance += details.primaryDelta ?? 0,
    onHorizontalDragEnd: (details) {
      final direction = widget.direction;
      final distance = _distance * direction;
      final velocity = (details.primaryVelocity ?? 0) * direction;
      if (ModalRoute.of(context)?.isCurrent == true &&
          (distance >= 70 && velocity > -300 ||
              distance >= 28 && velocity > 500)) {
        widget.onBack();
      }
    },
  );
}
