/// Web entry point for Flutter's plugin registrant.
///
/// `pubspec.yaml` declares this file as the plugin's web implementation, which
/// is how pub.dev and the Flutter tooling know the package supports the web.
/// There is nothing to register: the WebAssembly bundle is loaded by
/// `lib/src/bridge/bridge_web.dart` the first time a compiler is created, so
/// [TypstFlutterWeb.registerWith] is intentionally empty.
library;

/// Web plugin registration.
abstract final class TypstFlutterWeb {
  /// Called by Flutter's generated web plugin registrant.
  ///
  /// [registrar] is supplied by Flutter and is unused here.
  static void registerWith([Object? registrar]) {}
}
