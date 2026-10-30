/// Platform-specific initialisation of the Rust bridge.
///
/// Native platforms load a dynamic library; web loads a WebAssembly bundle.
/// Everything else in the package talks to the bridge through this one call.
library;

export 'bridge_io.dart' if (dart.library.js_interop) 'bridge_web.dart';
