import 'package:path/path.dart' as p;

/// The GitHub repository release assets are downloaded from.
///
/// The default comes from the package's own `pubspec.yaml`, so a fork
/// resolves to its own releases instead of the upstream ones — the reason a
/// fork's `setup --web` used to 404.
class RepositorySlug {
  /// Creates a slug.
  const RepositorySlug(this.owner, this.name);

  /// Parses `owner/name`. Returns null if the string is not that shape.
  static RepositorySlug? parse(String value) {
    final parts = value
        .trim()
        .split('/')
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.length != 2) return null;
    return RepositorySlug(_stripGit(parts[0]), _stripGit(parts[1]));
  }

  /// Parses the `repository:` URL of a `pubspec.yaml`.
  static RepositorySlug? fromRepositoryUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.host.isEmpty) return null;
    final segments = uri.pathSegments.where((part) => part.isNotEmpty).toList();
    if (segments.length < 2) return null;
    return RepositorySlug(
      _stripGit(segments[segments.length - 2]),
      _stripGit(segments.last),
    );
  }

  /// Repository owner or organisation.
  final String owner;

  /// Repository name.
  final String name;

  static String _stripGit(String value) =>
      value.endsWith('.git') ? value.substring(0, value.length - 4) : value;

  @override
  String toString() => '$owner/$name';
}

/// Command-line options for `dart run typst_flutter:setup`.
///
/// Lives in `lib/` (not `bin/`) so the parsing and path rules can be tested
/// without running the downloader. It must stay free of `dart:io` and
/// `dart:ffi`, like the rest of `lib/`.
class SetupOptions {
  /// Creates options; every field defaults to "not requested".
  const SetupOptions({
    this.version,
    this.noVerify = false,
    this.force = false,
    this.allPlatforms = false,
    this.includeWeb = false,
    this.repo,
    this.local = false,
    this.from,
  });

  /// Parses the command line, ignoring unknown arguments.
  factory SetupOptions.parse(List<String> args) {
    String? version;
    var noVerify = false;
    var force = false;
    var allPlatforms = false;
    var includeWeb = false;
    var local = false;
    String? from;
    RepositorySlug? repo;

    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '--no-verify') {
        noVerify = true;
      } else if (arg == '--force') {
        force = true;
      } else if (arg == '--all-platforms') {
        allPlatforms = true;
      } else if (arg == '--web') {
        includeWeb = true;
      } else if (arg == '--local') {
        local = true;
      } else if (arg == '--from' && i + 1 < args.length) {
        from = args[++i];
        local = true;
      } else if (arg.startsWith('--from=')) {
        from = arg.substring('--from='.length);
        local = true;
      } else if (arg == '--repo' && i + 1 < args.length) {
        repo = RepositorySlug.parse(args[++i]);
      } else if (arg.startsWith('--repo=')) {
        repo = RepositorySlug.parse(arg.substring('--repo='.length));
      } else if (arg == '--version' && i + 1 < args.length) {
        version = args[++i];
      } else if (arg.startsWith('--version=')) {
        version = arg.substring('--version='.length);
      }
    }

    return SetupOptions(
      version: version,
      noVerify: noVerify,
      force: force,
      allPlatforms: allPlatforms,
      includeWeb: includeWeb,
      repo: repo,
      local: local,
      from: from,
    );
  }

  /// Version to download; defaults to the one in `pubspec.yaml`.
  final String? version;

  /// Skips SHA-256 verification.
  final bool noVerify;

  /// Re-downloads even when the requested version is already present.
  final bool force;

  /// Downloads native libraries for every platform (used in CI).
  final bool allPlatforms;

  /// Downloads the WebAssembly bundle as well. Never implied: a native-only
  /// app should not receive web files it did not ask for.
  final bool includeWeb;

  /// Install from locally built artifacts instead of downloading a release.
  ///
  /// True when `--local` or `--from` was given. Nothing is downloaded and no
  /// checksum is verified; whatever the local build produced is what gets
  /// installed.
  final bool local;

  /// Directory to take local artifacts from.
  ///
  /// Null with [local] means "the package checkout's own build outputs"
  /// (`rust/target/**/release` and `example/web/pkg`).
  final String? from;

  /// Whether artifacts come from this machine rather than from a release.
  bool get isLocal => local;

  /// Maps a host library produced by `cargo build --release` to the release
  /// asset name it stands in for. Returns null for anything else.
  static String? releaseNameForBuildOutput(String fileName) =>
      switch (fileName) {
        'libtypst_flutter.a' => 'libtypst_flutter_macos.a',
        'libtypst_flutter.so' => 'libtypst_flutter_linux_x64.so',
        'typst_flutter.dll' => 'typst_flutter_windows_x64.dll',
        _ => null,
      };

  /// Maps a cargo target triple to the Android ABI directory it belongs in.
  static String? androidAbiForTarget(String target) => switch (target) {
    'aarch64-linux-android' => 'arm64-v8a',
    'armv7-linux-androideabi' => 'armeabi-v7a',
    'x86_64-linux-android' => 'x86_64',
    'i686-linux-android' => 'x86',
    _ => null,
  };

  /// Repository to download release assets from.
  ///
  /// Set with `--repo owner/name` or `TYPST_FLUTTER_REPO`; otherwise derived
  /// from the package's `pubspec.yaml`, so a fork points at its own releases.
  final RepositorySlug? repo;

  /// Where the wasm bundle goes: the *consuming app's* `web/pkg`, because the
  /// app's web root is what a browser serves.
  String webDestinationFor(String cwd) => p.join(cwd, 'web', 'pkg');

  /// Maps an archive entry name to the path it should be written to, relative
  /// to [webDestinationFor].
  ///
  /// The release tarball is built with `-C dist pkg`, so its entries start
  /// with `pkg/`; that prefix is dropped because the destination already ends
  /// in `pkg`. Returns null for entries that would escape the destination.
  String? webEntryPath(String entryName) {
    if (p.isAbsolute(entryName)) return null;
    if (p.split(entryName).contains('..')) return null;
    const prefix = 'pkg/';
    return entryName.startsWith(prefix)
        ? entryName.substring(prefix.length)
        : entryName;
  }

  /// The stamp that records which version the web bundle was unpacked from.
  ///
  /// Separate from the native stamp (`.typst_flutter_prebuilt/.version`,
  /// which lives in the package root) because the web bundle belongs to the
  /// app directory, not to the package.
  String webVersionStampFor(String cwd) =>
      p.join(webDestinationFor(cwd), '.typst_flutter_web_version');
}
