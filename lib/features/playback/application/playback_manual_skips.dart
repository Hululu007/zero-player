part of 'playback_controller.dart';

extension _PlaybackManualSkips on PlaybackController {
  void _applySkip() {
    if (_filterSeeking || _expectedSeek != null) return;
    for (final mark in marks) {
      final difference = (mark.duration - originalDuration).inMicroseconds
          .abs();
      if (!mark.enabled || difference > 2000000 || _skipped.contains(mark.id)) {
        continue;
      }
      if (originalPosition >= mark.start && originalPosition < mark.end) {
        final end = mark.end < originalDuration ? mark.end : originalDuration;
        if (end <= originalPosition) continue;
        _skipped.add(mark.id);
        _undoPosition = originalPosition;
        notice = '已跳过 ${mark.label}，可撤销';
        _filterSeeking = true;
        final generation = _generation;
        unawaited(
          seek(end, rearmSkips: false)
              .catchError((Object _) {
                if (!_closed && generation == _generation) {
                  _skipped.remove(mark.id);
                  notice = '跳过失败，可手动拖动后重试';
                }
              })
              .whenComplete(() {
                if (generation == _generation) _filterSeeking = false;
              }),
        );
        break;
      }
    }
  }

  void _rearmSkips() {
    _skipped.clear();
    _detected.clear();
    pendingFeature = null;
  }
}
