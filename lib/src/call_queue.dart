import 'dart:async';
import 'dart:collection';

/// One queue for every asynchronous call this package makes into Rust.
///
/// On a native platform the queue is a courtesy: the calls would mostly be safe
/// to overlap, and running them one at a time costs nothing next to a compile.
/// In a browser it is the difference between working and trapping.
///
/// The wasm build runs each call on its own worker thread, and those threads
/// cannot park: `parking_lot`'s wasm parker panics with `Parking not supported
/// on this platform` rather than blocking. Typst's memoization cache (`comemo`)
/// is process-wide and behind `parking_lot` locks, so two calls that run at the
/// same moment - a compile on one engine while a page is rendered on another,
/// which is exactly what a preview does while the author types - do not wait
/// for each other, they take the wasm instance down with an `unreachable`
/// trap. The call that traps fails, and from the caller's side it fails
/// quietly.
///
/// So everything asynchronous goes through here instead: `compile`, `addFonts`,
/// `query`, `renderRaster`, `renderSvg` and `exportPdf`, across every compiler
/// and every document, because the cache they contend on is not per engine.
/// Calls that are `#[frb(sync)]` (`pageCount`, `pageInfo`, `warnings`,
/// `dispose`) stay out of it: they run on the calling thread, and in a browser
/// they fail immediately rather than parking, which is a different problem with
/// a different answer.
class RustCallQueue {
  /// The calls waiting for the slot, oldest first.
  ///
  /// A queue of completers rather than a chain of futures, and deliberately: a
  /// chain's next link is a `then` continuation, which runs in the zone that
  /// created it. A caller that abandons a call - a widget test that ends while
  /// one is in flight, say - would then leave the chain unsettled and every
  /// later call waiting for ever. Handing the slot over from the running call's
  /// `finally` keeps the signal in the queue itself, where no caller's lifetime
  /// can strand it.
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  /// Whether a call holds the slot.
  bool _busy = false;

  int _running = 0;
  int _peak = 0;

  /// How many calls are in flight right now.
  ///
  /// One, unless something is wrong: the queue's whole contract is that this
  /// never rises above one, and a test asserts it.
  int get running => _running;

  /// The most calls that have ever been in flight at once, for a test to read.
  int get peakRunning => _peak;

  /// Runs [call] once every call enqueued before it has finished.
  ///
  /// The answer and its error are the caller's either way; a failed call does
  /// not hold up the ones behind it, because the slot is handed on in a
  /// `finally`.
  Future<T> run<T>(Future<T> Function() call) async {
    if (_busy) {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    } else {
      _busy = true;
    }
    _running++;
    if (_running > _peak) _peak = _running;
    try {
      return await call();
    } finally {
      _running--;
      if (_waiters.isEmpty) {
        _busy = false;
      } else {
        _waiters.removeFirst().complete();
      }
    }
  }
}

/// The queue every asynchronous call into Rust goes through.
///
/// Process-wide on purpose: the locks the calls contend on are shared by every
/// compiler and document, so a queue per compiler would leave the
/// compile-while-rendering case - the one a preview hits - unsolved.
final RustCallQueue rustCalls = RustCallQueue();
