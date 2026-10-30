// Print statements are intentional in this CLI setup script.
// ignore_for_file: lines_longer_than_80_chars, avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:typst_flutter/src/setup/setup_options.dart';

// ── Entry point ──────────────────────────────────────────────────────────────

void main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    _printHelp();
    exit(0);
  }

  final options = SetupOptions.parse(args);
  final setup = _Setup(options);
  await setup.run();
}

// ── Configuration ────────────────────────────────────────────────────────────

const _repoOwner = 'ajmalbuv';
const _repoName = 'typst_flutter';
const _prebuiltDir = '.typst_flutter_prebuilt';
const _versionFile = '$_prebuiltDir/.version';

void _printHelp() {
  print('''
dart run typst_flutter:setup [options]

Downloads pre-built native Typst compiler libraries from GitHub Releases
and places them where Flutter's build system can find them.
Run this once after `flutter pub get`.

By default only the libraries for the current host platform are downloaded.
Use --all-platforms to download everything (useful in CI).

Options:
  --version <v>     Specific version to download (e.g. 1.0.0). Defaults to
                    the version declared in pubspec.yaml.
  --force           Re-download even if the correct version is already present.
  --no-verify       Skip SHA-256 checksum verification.
  --all-platforms   Download binaries for every supported platform.
  --web             Also download the WebAssembly bundle for Flutter web and
                    unpack it into <current dir>/web/pkg. The app must then be
                    served with Cross-Origin-Opener-Policy: same-origin and
                    Cross-Origin-Embedder-Policy: require-corp.
  --help            Show this help.
''');
}

// ── Artifact definitions ─────────────────────────────────────────────────────

class _Artifact {
  const _Artifact({required this.filename, required this.destination});

  /// Filename as published on GitHub Releases.
  final String filename;

  /// Path relative to [_prebuiltDir] where the file should be placed.
  final String destination;
}

/// Returns only the artifacts required for [platform].
///
/// [platform] should be `Platform.operatingSystem` (e.g. `'macos'`,
/// `'linux'`, `'windows'`).
///
/// Mobile build machines (iOS builds on macOS, Android builds on any OS)
/// include the host-OS library plus the relevant mobile artifacts so that
/// a single CI runner can cover both the host app and the mobile target.
List<_Artifact> _artifactsForPlatform(String platform) {
  // Android — all 4 ABIs are always included regardless of host OS because
  // Gradle can cross-compile from any host.
  const androidArtifacts = [
    _Artifact(
      filename: 'libtypst_flutter_android_arm64.so',
      destination: 'android/arm64-v8a/libtypst_flutter.so',
    ),
    _Artifact(
      filename: 'libtypst_flutter_android_armv7.so',
      destination: 'android/armeabi-v7a/libtypst_flutter.so',
    ),
    _Artifact(
      filename: 'libtypst_flutter_android_x64.so',
      destination: 'android/x86_64/libtypst_flutter.so',
    ),
    _Artifact(
      filename: 'libtypst_flutter_android_x86.so',
      destination: 'android/x86/libtypst_flutter.so',
    ),
  ];

  switch (platform) {
    case 'macos':
      // macOS runner can also build iOS and Android.
      return [
        const _Artifact(
          filename: 'libtypst_flutter_macos.a',
          destination: 'macos/libtypst_flutter.a',
        ),
        const _Artifact(
          filename: 'libtypst_flutter_ios.xcframework.zip',
          destination: 'ios/',
        ),
        ...androidArtifacts,
      ];

    case 'linux':
      // Linux runner builds Linux desktop and Android.
      return [
        const _Artifact(
          filename: 'libtypst_flutter_linux_x64.so',
          destination: 'linux/libtypst_flutter.so',
        ),
        ...androidArtifacts,
      ];

    case 'windows':
      // Windows runner builds Windows desktop and Android.
      return [
        const _Artifact(
          filename: 'typst_flutter_windows_x64.dll',
          destination: 'windows/typst_flutter.dll',
        ),
        ...androidArtifacts,
      ];

    default:
      // Unknown host — fall back to everything so setup never silently does
      // nothing on an unrecognised platform.
      return _allArtifacts();
  }
}

/// Returns artifacts for every platform. Used when --all-platforms is passed.
List<_Artifact> _allArtifacts() => [
  // Android — all 4 ABIs
  const _Artifact(
    filename: 'libtypst_flutter_android_arm64.so',
    destination: 'android/arm64-v8a/libtypst_flutter.so',
  ),
  const _Artifact(
    filename: 'libtypst_flutter_android_armv7.so',
    destination: 'android/armeabi-v7a/libtypst_flutter.so',
  ),
  const _Artifact(
    filename: 'libtypst_flutter_android_x64.so',
    destination: 'android/x86_64/libtypst_flutter.so',
  ),
  const _Artifact(
    filename: 'libtypst_flutter_android_x86.so',
    destination: 'android/x86/libtypst_flutter.so',
  ),
  // iOS — XCFramework zip (device + simulator)
  const _Artifact(
    filename: 'libtypst_flutter_ios.xcframework.zip',
    destination: 'ios/',
  ),
  // Desktop
  const _Artifact(
    filename: 'libtypst_flutter_linux_x64.so',
    destination: 'linux/libtypst_flutter.so',
  ),
  const _Artifact(
    filename: 'typst_flutter_windows_x64.dll',
    destination: 'windows/typst_flutter.dll',
  ),
  const _Artifact(
    filename: 'libtypst_flutter_macos.a',
    destination: 'macos/libtypst_flutter.a',
  ),
];

// ── Setup orchestrator ───────────────────────────────────────────────────────

class _Setup {
  _Setup(this._opts);
  final SetupOptions _opts;

  late final String _packageRoot;
  late final String _version;
  late final Map<String, String> _sha256sums;

  Future<void> run() async {
    _packageRoot = await _findPackageRoot();
    _version = _opts.version ?? _readVersion();

    print('╔══════════════════════════════════════════════════╗');
    print('║        typst_flutter native library setup        ║');
    print('╚══════════════════════════════════════════════════╝');
    print('');
    print('  Package root : $_packageRoot');
    print('  Version      : $_version');
    print('  Verify SHA   : ${!_opts.noVerify}');
    print('');

    // Check if already up-to-date
    if (!_opts.force && _isUpToDate()) {
      print('✓ Pre-built libraries for v$_version are already present.');
      print('  (Run with --force to re-download.)');
      return;
    }

    // Fetch checksums
    if (!_opts.noVerify) {
      print('⟳ Fetching SHA256SUMS …');
      _sha256sums = await _fetchChecksums();
      print('  Got ${_sha256sums.length} checksum entries.');
    } else {
      _sha256sums = {};
    }

    // Download platform-appropriate artifacts
    final platform = Platform.operatingSystem;
    final artifacts = _opts.allPlatforms
        ? _allArtifacts()
        : _artifactsForPlatform(platform);

    print(
      '  Platform     : $platform${_opts.allPlatforms ? " (all platforms mode)" : ""}',
    );
    print('  Artifacts    : ${artifacts.length}');
    print('');

    var downloaded = 0;

    for (final artifact in artifacts) {
      try {
        await _downloadArtifact(artifact);
        downloaded++;
      } on Exception catch (e) {
        // Non-fatal: some platforms may not have every artifact yet.
        print('  ⚠  Skipped ${artifact.filename}: $e');
      }
    }

    // Write version stamp
    final versionPath = p.join(_packageRoot, _prebuiltDir, '.version');
    File(versionPath).writeAsStringSync(_version);

    print('');
    print('✓ Done! Downloaded $downloaded/${artifacts.length} artifacts.');
    print('  Libraries for $platform are ready.');
    print('  You can now build your Flutter app without Rust installed.');

    if (_opts.includeWeb) {
      await _downloadWeb();
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  bool _isUpToDate() {
    final stampPath = p.join(_packageRoot, _versionFile);
    final stampFile = File(stampPath);
    if (!stampFile.existsSync()) return false;
    return stampFile.readAsStringSync().trim() == _version;
  }

  /// Downloads `typst_flutter_web.tar.gz` and unpacks it into the current
  /// working directory's `web/pkg`, which is what a browser serves.
  Future<void> _downloadWeb() async {
    const assetName = 'typst_flutter_web.tar.gz';
    final cwd = Directory.current.path;
    final destination = _opts.webDestinationFor(cwd);
    final stampPath = _opts.webVersionStampFor(cwd);

    print('');
    print('── Web (WebAssembly) ──────────────────────────────────────');
    print('  Destination  : $destination');

    final stamp = File(stampPath);
    if (!_opts.force &&
        stamp.existsSync() &&
        stamp.readAsStringSync().trim() == _version) {
      print('✓ Web bundle for v$_version is already present.');
      _printWebInstructions();
      return;
    }

    final url =
        'https://github.com/$_repoOwner/$_repoName/releases/download/v$_version/$assetName';
    print('⟳ $assetName');

    final response = await http.get(Uri.parse(url));
    if (response.statusCode == 404) {
      throw Exception(
        'Web bundle not found on GitHub Releases (HTTP 404). '
        'Check that v$_version has been released.',
      );
    }
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode} for $url');
    }

    final bytes = response.bodyBytes;
    if (!_opts.noVerify && _sha256sums.isNotEmpty) {
      final expected = _sha256sums[assetName];
      if (expected != null) {
        final actual = sha256.convert(bytes).toString();
        if (actual != expected) {
          throw Exception(
            'SHA-256 mismatch for $assetName!\n'
            '  expected: $expected\n'
            '  actual  : $actual',
          );
        }
      } else {
        print('    (no checksum entry for $assetName — skipping verification)');
      }
    }

    final tarBytes = const GZipDecoder().decodeBytes(bytes);
    final archive = TarDecoder().decodeBytes(tarBytes);
    var extracted = 0;
    for (final entry in archive.files) {
      if (!entry.isFile) continue;
      final relative = _opts.webEntryPath(entry.name);
      if (relative == null) continue;
      final target = p.join(destination, p.joinAll(relative.split('/')));
      File(target).createSync(recursive: true);
      File(target).writeAsBytesSync(entry.content as List<int>);
      extracted++;
    }

    Directory(p.dirname(stampPath)).createSync(recursive: true);
    File(stampPath).writeAsStringSync(_version);

    final mb = (bytes.length / (1024 * 1024)).toStringAsFixed(1);
    print('  ✓ $extracted files into $destination ($mb MB compressed)');
    _printWebInstructions();
  }

  void _printWebInstructions() {
    print('');
    print('  Serve the app with these response headers, or the wasm cannot');
    print('  use worker threads:');
    print('    Cross-Origin-Opener-Policy: same-origin');
    print('    Cross-Origin-Embedder-Policy: require-corp');
    print('  Dev server:');
    print(r'    flutter run -d chrome --wasm \');
    print(r'      --web-header=Cross-Origin-Opener-Policy=same-origin \');
    print('      --web-header=Cross-Origin-Embedder-Policy=require-corp');
  }

  Future<void> _downloadArtifact(_Artifact artifact) async {
    final url =
        'https://github.com/$_repoOwner/$_repoName/releases/download/v$_version/${artifact.filename}';
    final destPath = p.join(
      _packageRoot,
      _prebuiltDir,
      p.joinAll(artifact.destination.split('/')),
    );

    print('⟳ ${artifact.filename}');

    // Ensure destination directory exists
    final destDir = Directory(p.dirname(destPath));
    if (!destDir.existsSync()) destDir.createSync(recursive: true);

    // Download to memory
    final response = await http.get(Uri.parse(url));

    if (response.statusCode == 404) {
      throw Exception(
        'Not found on GitHub Releases (HTTP 404). '
        'Check that v$_version has been released.',
      );
    }
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }

    final bytes = response.bodyBytes;

    // Verify SHA-256
    if (!_opts.noVerify && _sha256sums.isNotEmpty) {
      final expected = _sha256sums[artifact.filename];
      if (expected != null) {
        final actual = sha256.convert(bytes).toString();
        if (actual != expected) {
          throw Exception(
            'SHA-256 mismatch for ${artifact.filename}!\n'
            '  expected: $expected\n'
            '  actual  : $actual',
          );
        }
      } else {
        print(
          '    (no checksum entry for '
          '${artifact.filename} — skipping verification)',
        );
      }
    }

    // Write/extract file
    if (artifact.filename.endsWith('.zip')) {
      final archive = ZipDecoder().decodeBytes(bytes);
      await extractArchiveToDisk(archive, destPath);
    } else {
      File(destPath).writeAsBytesSync(bytes);
    }

    final kb = (bytes.length / 1024).toStringAsFixed(1);
    print('  ✓ ${artifact.destination} ($kb KB)');
  }

  Future<Map<String, String>> _fetchChecksums() async {
    final baseUrl =
        'https://github.com/$_repoOwner/$_repoName'
        '/releases/download/v$_version/SHA256SUMS';
    final response = await http.get(Uri.parse(baseUrl));

    if (response.statusCode != 200) {
      print(
        '  ⚠  Could not fetch SHA256SUMS (HTTP ${response.statusCode}). '
        'Proceeding without verification.',
      );
      return {};
    }

    // Format: "<sha256>  <filename>\n"
    final result = <String, String>{};
    for (final line in const LineSplitter().convert(response.body)) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length >= 2) {
        result[parts[1]] = parts[0];
      }
    }
    return result;
  }

  /// Finds the typst_flutter package root by resolving its package URI.
  Future<String> _findPackageRoot() async {
    final uri = await Isolate.resolvePackageUri(
      Uri.parse('package:typst_flutter/typst_flutter.dart'),
    );

    if (uri == null) {
      throw StateError(
        'Could not resolve package:typst_flutter. '
        'Make sure the package is in your pubspec.yaml and you have run flutter pub get.',
      );
    }

    // uri is usually file:///path/to/typst_flutter/lib/typst_flutter.dart
    // We want the directory containing pubspec.yaml, which is one level up from lib/
    final libDir = p.dirname(uri.toFilePath());
    return p.dirname(libDir);
  }

  /// Reads the package version from pubspec.yaml.
  String _readVersion() {
    final pubspecPath = p.join(_packageRoot, 'pubspec.yaml');
    final content = File(pubspecPath).readAsStringSync();
    final match = RegExp(
      r'^version:\s*(.+)$',
      multiLine: true,
    ).firstMatch(content);
    if (match == null) {
      throw StateError('Could not read version from pubspec.yaml');
    }
    return match.group(1)!.trim();
  }
}
