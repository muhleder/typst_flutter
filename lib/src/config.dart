/// Process-wide configuration for typst_flutter.
///
/// Call [TypstFlutter.configure] once at startup when the Typst package
/// registry used by web builds lives somewhere other than
/// `https://packages.typst.org`. Widgets that create their own compiler
/// (`TypstView.source`, `TypstDocumentViewer`, `TypstCompilerProvider`) pick
/// the value up, so there is no need to thread it through every constructor.
///
/// ```dart
/// void main() {
///   TypstFlutter.configure(packageRegistryUrl: 'https://typst.example.com');
///   runApp(const MyApp());
/// }
/// ```
///
/// Both settings are ignored on Android, iOS, macOS, Windows and Linux, where
/// the compiler is a native library and downloads happen in Rust.
abstract final class TypstFlutter {
  static String? _packageRegistryUrl;

  /// Overrides the process-wide defaults.
  ///
  /// [packageRegistryUrl] is the base URL of the Typst package registry used
  /// by the web prefetcher. It defaults to `https://packages.typst.org`.
  static void configure({String? packageRegistryUrl}) {
    _packageRegistryUrl = packageRegistryUrl ?? _packageRegistryUrl;
  }

  /// The registry packages are downloaded from on web.
  static String get packageRegistryUrl =>
      _packageRegistryUrl ?? 'https://packages.typst.org';
}
