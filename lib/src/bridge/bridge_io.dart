import 'package:typst_flutter/src/rust/frb_generated.dart';

/// Initialises the native bridge from the bundled dynamic library.
Future<void> initWithOptionalWebModule({String? webModuleRoot}) =>
    RustLib.init();
