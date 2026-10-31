import 'dart:js_interop';

import 'package:typst_flutter/src/exceptions.dart';
import 'package:typst_flutter/src/rust/frb_generated.dart';
import 'package:web/web.dart' as web;

/// Where `dart run typst_flutter:setup --web` writes the bundle, relative to
/// the page. It matches the `webPrefix` generated code uses; hosting the
/// bundle elsewhere is a codegen configuration change, not a runtime one.
const _bundleRoot = 'pkg/typst_flutter';

/// Initialises the bridge from the WebAssembly bundle.
///
/// The bundle is loaded by flutter_rust_bridge itself; this function exists to
/// fail loudly when it is missing. FRB's loader waits on `onload` only, so a
/// 404 would hang the `await` forever.
Future<void> initWithOptionalWebModule({String? webModuleRoot}) async {
  final root = webModuleRoot ?? _bundleRoot;
  await _ensureReachable('$root.js', 'Run: dart run typst_flutter:setup --web');
  await _ensureReachable(
    '${root}_bg.wasm',
    'Run: dart run typst_flutter:setup --web',
  );

  if (!web.window.crossOriginIsolated) {
    web.console.warn(
      'typst_flutter: this page is not cross-origin isolated. The shared '
              'wasm memory it needs requires Cross-Origin-Opener-Policy: '
              'same-origin and Cross-Origin-Embedder-Policy: require-corp.'
          .toJS,
    );
  }

  await RustLib.init();
}

/// Throws a [TypstWebSetupException] unless [url] can be served.
///
/// The check asks with a ranged `GET` rather than a `HEAD`, because a server
/// that does not implement `HEAD` answers it with a `404` for a file it is
/// serving: `flutter run`'s dev server does exactly that, for
/// `pkg/typst_flutter.js` and `index.html` alike, and a `HEAD` here reported a
/// bundle that was there as missing - the one failure a developer is guaranteed
/// to hit, since it is the first thing a web build does.
///
/// The range keeps the check from downloading the bundle: the wasm is ~23 MB
/// and flutter_rust_bridge fetches it itself a moment later. The body is
/// cancelled as soon as the status is in hand, so a host that ignores `Range`
/// costs one aborted response rather than a second copy of the file.
///
/// A host that refuses the range is not an error either: `416` (range not
/// satisfiable) and `405`/`501` (not implemented) both mean the URL was answered.
Future<void> _ensureReachable(String url, String fix) async {
  final range = web.Headers()..set('Range', 'bytes=0-0');
  final response = await web.window
      .fetch(url.toJS, web.RequestInit(method: 'GET', headers: range))
      .toDart;
  final body = response.body;
  if (body != null) await body.cancel().toDart;

  final status = response.status;
  if (status >= 200 && status < 300) return;
  if (status == 405 || status == 416 || status == 501) return;
  throw TypstWebSetupException('Could not load $url (HTTP $status). $fix');
}
