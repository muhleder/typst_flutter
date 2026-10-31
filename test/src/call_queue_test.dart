import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:typst_flutter/src/call_queue.dart';

// Every asynchronous call the package makes into Rust goes through one queue.
// On the web that is what keeps two calls from running at once: the wasm
// threads cannot park, `parking_lot` panics instead, and typst's memo cache is
// process-wide - so a compile during a page render does not wait for the
// render, it traps. These pin the queue's contract, which is the whole of that
// fix.

void main() {
  test(
    'two calls never run at once, however many are asked for together',
    () async {
      final queue = RustCallQueue();
      final gates = <Completer<void>>[];
      final order = <int>[];

      final calls = <Future<void>>[
        for (int i = 0; i < 4; i++)
          queue.run(() async {
            order.add(i);
            final gate = Completer<void>();
            gates.add(gate);
            await gate.future;
          }),
      ];

      // The first call takes the slot at once - no free-threaded start means a
      // caller cannot be surprised by a delay it did not ask for - and the rest
      // wait their turn behind it.
      expect(order, <int>[0]);
      for (var i = 0; i < 4; i++) {
        while (gates.length <= i) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(queue.running, 1);
        expect(order, <int>[for (int j = 0; j <= i; j++) j]);
        gates[i].complete();
        await Future<void>.delayed(Duration.zero);
      }
      await Future.wait(calls);

      expect(order, <int>[
        0,
        1,
        2,
        3,
      ], reason: 'a queue is first in, first out');
      expect(
        queue.peakRunning,
        1,
        reason: 'two at once is the crash this prevents',
      );
      expect(queue.running, 0);
    },
  );

  test('a call that fails does not hold up the ones behind it', () async {
    final queue = RustCallQueue();
    final ran = <String>[];

    final failing = queue.run<String>(() async {
      ran.add('first');
      throw StateError('no pdf today');
    });

    final following = queue.run<String>(() async {
      ran.add('second');
      return 'second ok';
    });

    await expectLater(failing, throwsStateError);
    expect(await following, 'second ok');
    expect(ran, <String>['first', 'second']);
    expect(queue.running, 0);
  });

  test('each caller gets its own answer', () async {
    final queue = RustCallQueue();
    final answers = await Future.wait<int>(<Future<int>>[
      queue.run(() async => 1),
      queue.run(() async => 2),
      queue.run(() async => 3),
    ]);
    expect(answers, <int>[1, 2, 3]);
  });
}
