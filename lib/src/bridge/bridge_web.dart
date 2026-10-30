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

/// Throws a [TypstWebSetupException] unless [url] returns a successful
/// response. A server that rejects `HEAD` is given the benefit of the doubt:
/// only a definite client/server error fails here.
///
/// `HEAD` matters: the wasm is ~23 MB, and a `GET` here would download it once
/// for this check and once more for flutter_rust_bridge's own loader.
Future<void> _ensureReachable(String url, String fix) async {
  final response = await web.window
      .fetch(url.toJS, web.RequestInit(method: 'HEAD'))
      .toDart;
  if (response.ok) return;
  final status = response.status;
  if (status == 405 || status == 501) return;
  throw TypstWebSetupException('Could not load $url (HTTP $status). $fix');
}
