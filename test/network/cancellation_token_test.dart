import 'package:flutter_test/flutter_test.dart';
import 'package:zero_player/core/network/cancellation_token.dart';

void main() {
  test('cancel runs every listener and rethrows the first error only once', () {
    final token = CancellationToken();
    final first = StateError('first listener');
    final second = StateError('second listener');
    final calls = <String>[];
    token.listen(() {
      calls.add('first');
      throw first;
    });
    token.listen(() => calls.add('network aborted'));
    token.listen(() {
      calls.add('second');
      throw second;
    });
    token.listen(() => calls.add('last'));
    expect(token.cancel, throwsA(same(first)));
    expect(token.isCancelled, isTrue);
    expect(calls, ['first', 'network aborted', 'second', 'last']);
    token.cancel();
    expect(calls, hasLength(4));
    token.listen(() => calls.add('late'));
    expect(calls.last, 'late');
  });
}
