import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:typst_flutter/src/setup/setup_options.dart';

import '../bin/setup.dart';

/// A `.tar.gz` shaped like the release asset: `pkg/typst_flutter.js` +
/// `pkg/typst_flutter_bg.wasm`.
List<int> _webBundleTarball() {
  final archive = Archive();
  for (final name in const [
    'pkg/typst_flutter.js',
    'pkg/typst_flutter_bg.wasm',
  ]) {
    final bytes = utf8.encode('content of $name');
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }
  return const GZipEncoder().encode(TarEncoder().encode(archive));
}

void main() {
  group('SetupRunner --web', () {
    late Directory root;
    late String appDir;
    late String packageDir;
    late List<String> requested;

    setUp(() {
      root = Directory.systemTemp.createTempSync('typst_setup_test');
      appDir = p.join(root.path, 'app');
      packageDir = p.join(root.path, 'pkg');
      Directory(appDir).createSync(recursive: true);
      Directory(
        p.join(packageDir, '.typst_flutter_prebuilt'),
      ).createSync(recursive: true);
      requested = <String>[];
    });

    tearDown(() => root.deleteSync(recursive: true));

    Future<http.Response> fakeGet(Uri url) async {
      requested.add(url.toString());
      if (url.path.endsWith('SHA256SUMS')) {
        return http.Response('', 200);
      }
      if (url.path.endsWith('typst_flutter_web.tar.gz')) {
        return http.Response.bytes(_webBundleTarball(), 200);
      }
      return http.Response('not found', 404);
    }

    test(
      'downloads the bundle even when the native stamp is current',
      () async {
        // The exact situation after `dart run typst_flutter:setup` on a machine
        // that already has native libraries for this version.
        File(
          p.join(packageDir, '.typst_flutter_prebuilt', '.version'),
        ).writeAsStringSync('9.9.9');

        await SetupRunner(
          SetupOptions.parse(['--web', '--version', '9.9.9']),
          httpGet: fakeGet,
          packageRoot: packageDir,
          workingDirectory: appDir,
        ).run();

        expect(
          requested.where((url) => url.endsWith('typst_flutter_web.tar.gz')),
          isNotEmpty,
          reason: 'the web bundle must be fetched despite native being current',
        );
        expect(
          File(
            p.join(appDir, 'web', 'pkg', 'typst_flutter_bg.wasm'),
          ).existsSync(),
          isTrue,
        );
        expect(
          File(p.join(appDir, 'web', 'pkg', 'typst_flutter.js')).existsSync(),
          isTrue,
        );
        expect(
          File(
            p.join(appDir, 'web', 'pkg', '.typst_flutter_web_version'),
          ).readAsStringSync(),
          '9.9.9',
        );
      },
    );

    test('a native-only run never touches web/', () async {
      File(
        p.join(packageDir, '.typst_flutter_prebuilt', '.version'),
      ).writeAsStringSync('9.9.9');

      await SetupRunner(
        SetupOptions.parse(['--version', '9.9.9']),
        httpGet: fakeGet,
        packageRoot: packageDir,
        workingDirectory: appDir,
      ).run();

      expect(
        requested.where((url) => url.endsWith('typst_flutter_web.tar.gz')),
        isEmpty,
      );
      expect(Directory(p.join(appDir, 'web')).existsSync(), isFalse);
    });

    group('local mode', () {
      test(
        '--from installs release-shaped artifacts without any download',
        () async {
          final dist = Directory(p.join(root.path, 'dist'))..createSync();
          for (final name in const [
            'libtypst_flutter_macos.a',
            'libtypst_flutter_linux_x64.so',
            'typst_flutter_windows_x64.dll',
          ]) {
            File(p.join(dist.path, name)).writeAsBytesSync([1, 2, 3]);
          }

          await SetupRunner(
            SetupOptions.parse([
              '--from',
              dist.path,
              '--version',
              '9.9.9',
              '--all-platforms',
            ]),
            httpGet: fakeGet,
            packageRoot: packageDir,
            workingDirectory: appDir,
            // The fixture's .a is not a real Mach-O, so stub the wrap out.
            createXcframework: ({required library, required output}) async {},
          ).run();

          expect(
            requested,
            isEmpty,
            reason: 'local mode must not touch the network',
          );
          expect(
            File(
              p.join(
                packageDir,
                '.typst_flutter_prebuilt',
                'macos',
                'libtypst_flutter.a',
              ),
            ).existsSync(),
            isTrue,
          );
          expect(
            File(
              p.join(
                packageDir,
                '.typst_flutter_prebuilt',
                'android',
                'arm64-v8a',
                'libtypst_flutter.so',
              ),
            ).existsSync(),
            isFalse,
            reason: 'nothing was built for Android in this fixture',
          );
        },
      );

      test(
        '--local reads cargo build outputs and the example web bundle',
        () async {
          // A fake checkout: rust/target/release + example/web/pkg
          final hostLib = switch (Platform.operatingSystem) {
            'macos' => 'libtypst_flutter.a',
            'windows' => 'typst_flutter.dll',
            _ => 'libtypst_flutter.so',
          };
          Directory(
            p.join(packageDir, 'rust', 'target', 'release'),
          ).createSync(recursive: true);
          File(
            p.join(packageDir, 'rust', 'target', 'release', hostLib),
          ).writeAsBytesSync([9, 9, 9]);
          final pkgDir = Directory(p.join(packageDir, 'example', 'web', 'pkg'))
            ..createSync(recursive: true);
          File(
            p.join(pkgDir.path, 'typst_flutter.js'),
          ).writeAsStringSync('// js');
          File(
            p.join(pkgDir.path, 'typst_flutter_bg.wasm'),
          ).writeAsBytesSync([0, 97, 115, 109]);

          await SetupRunner(
            SetupOptions.parse(['--local', '--web', '--version', '9.9.9']),
            httpGet: fakeGet,
            packageRoot: packageDir,
            workingDirectory: appDir,
            createXcframework: ({required library, required output}) async {},
          ).run();

          expect(requested, isEmpty);
          expect(
            File(
              p.join(appDir, 'web', 'pkg', 'typst_flutter_bg.wasm'),
            ).existsSync(),
            isTrue,
            reason: 'the locally built wasm must reach the app',
          );
          expect(
            File(
              p.join(packageDir, '.typst_flutter_prebuilt', '.version'),
            ).readAsStringSync(),
            '9.9.9',
          );
        },
      );

      test('--local without build outputs fails with instructions', () async {
        await expectLater(
          SetupRunner(
            SetupOptions.parse(['--local', '--version', '9.9.9']),
            httpGet: fakeGet,
            packageRoot: packageDir,
            workingDirectory: appDir,
          ).run(),
          throwsA(
            isA<Exception>().having(
              (e) => e.toString(),
              'message',
              allOf(contains('just build-host'), contains('--from')),
            ),
          ),
        );
      });
    });

    test('a fork downloads from its own repository', () async {
      // The reported bug: setup pointed at the upstream owner, so a fork's
      // release assets 404ed.
      File(p.join(packageDir, 'pubspec.yaml')).writeAsStringSync('''
name: typst_flutter
version: 9.9.9
repository: https://github.com/muhleder/typst_flutter
''');

      await SetupRunner(
        SetupOptions.parse(['--web', '--version', '9.9.9']),
        httpGet: fakeGet,
        packageRoot: packageDir,
        workingDirectory: appDir,
      ).run();

      expect(
        requested.where(
          (url) => url.startsWith(
            'https://github.com/muhleder/typst_flutter/releases/'
            'download/v9.9.9/',
          ),
        ),
        isNotEmpty,
        reason: 'a fork must fetch from its own releases',
      );
      expect(
        requested.where((url) => url.contains('ajmalbuv')),
        isEmpty,
        reason: 'upstream must not be contacted by a fork',
      );
    });

    test('--repo overrides the pubspec repository', () async {
      File(p.join(packageDir, 'pubspec.yaml')).writeAsStringSync('''
name: typst_flutter
version: 9.9.9
repository: https://github.com/muhleder/typst_flutter
''');

      await SetupRunner(
        SetupOptions.parse([
          '--web',
          '--version',
          '9.9.9',
          '--repo',
          'someone/elsewhere',
        ]),
        httpGet: fakeGet,
        packageRoot: packageDir,
        workingDirectory: appDir,
      ).run();

      expect(
        requested.where((url) => url.contains('someone/elsewhere')),
        isNotEmpty,
      );
    });

    test('a matching web stamp skips the download', () async {
      Directory(p.join(appDir, 'web', 'pkg')).createSync(recursive: true);
      File(
        p.join(appDir, 'web', 'pkg', '.typst_flutter_web_version'),
      ).writeAsStringSync('9.9.9');
      File(
        p.join(packageDir, '.typst_flutter_prebuilt', '.version'),
      ).writeAsStringSync('9.9.9');

      await SetupRunner(
        SetupOptions.parse(['--web', '--version', '9.9.9']),
        httpGet: fakeGet,
        packageRoot: packageDir,
        workingDirectory: appDir,
      ).run();

      expect(
        requested.where((url) => url.endsWith('typst_flutter_web.tar.gz')),
        isEmpty,
      );
    });
  });

  group('apple swift package artifacts', () {
    late Directory root;
    late String packageDir;
    late String appDir;
    late List<({String library, String output})> wrapCalls;

    setUp(() {
      root = Directory.systemTemp.createTempSync('typst_setup_apple');
      packageDir = p.join(root.path, 'pkg');
      appDir = p.join(root.path, 'app');
      Directory(packageDir).createSync(recursive: true);
      Directory(appDir).createSync(recursive: true);
      wrapCalls = [];
    });

    tearDown(() => root.deleteSync(recursive: true));

    /// A zip shaped like `libtypst_flutter_ios.xcframework.zip`.
    List<int> iosZip() {
      final archive = Archive();
      for (final name in const [
        'typst_flutter.xcframework/Info.plist',
        'typst_flutter.xcframework/ios-arm64/libtypst_flutter.a',
      ]) {
        final bytes = utf8.encode(name);
        archive.addFile(ArchiveFile(name, bytes.length, bytes));
      }
      return ZipEncoder().encode(archive)!;
    }

    Future<http.Response> fakeGet(Uri url) async {
      if (url.path.endsWith('SHA256SUMS')) return http.Response('', 200);
      if (url.path.endsWith('libtypst_flutter_ios.xcframework.zip')) {
        return http.Response.bytes(iosZip(), 200);
      }
      if (url.path.endsWith('libtypst_flutter_macos.a')) {
        return http.Response.bytes(utf8.encode('staticlib'), 200);
      }
      return http.Response('not found', 404);
    }

    SetupRunner runner([List<String> extraArgs = const []]) => SetupRunner(
      SetupOptions.parse(['--version', '9.9.9', '--no-verify', ...extraArgs]),
      httpGet: fakeGet,
      packageRoot: packageDir,
      hostPlatform: 'macos',
      workingDirectory: appDir,
      createXcframework: ({required library, required output}) async =>
          wrapCalls.add((library: library, output: output)),
    );

    void writeStamp(String version) {
      final stamp = File(
        p.join(packageDir, '.typst_flutter_prebuilt', '.version'),
      )..createSync(recursive: true);
      stamp.writeAsStringSync(version);
    }

    test('unpacks the iOS xcframework inside the iOS SPM package', () async {
      await runner().run();
      expect(
        File(
          p.join(
            packageDir,
            'ios/typst_flutter/Binaries/typst_flutter.xcframework/Info.plist',
          ),
        ).existsSync(),
        isTrue,
      );
      expect(
        Directory(p.join(appDir, 'ios')).existsSync(),
        isFalse,
        reason: 'setup must write into the package, not the app that ran it',
      );
    });

    test('wraps the macOS static library into the macOS SPM package', () async {
      await runner().run();
      expect(wrapCalls, hasLength(1));
      expect(
        wrapCalls.single.library,
        p.join(packageDir, '.typst_flutter_prebuilt/macos/libtypst_flutter.a'),
      );
      expect(
        wrapCalls.single.output,
        p.join(
          packageDir,
          'macos/typst_flutter/Binaries/typst_flutter.xcframework',
        ),
      );
    });

    test('re-running with --force replaces instead of nesting', () async {
      await runner().run();
      await runner(['--force']).run();
      final binDir = Directory(
        p.join(packageDir, 'ios/typst_flutter/Binaries'),
      );
      expect(
        binDir.listSync().map((e) => p.basename(e.path)).toList(),
        ['typst_flutter.xcframework'],
        reason:
            'a second run must not create '
            'typst_flutter.xcframework/typst_flutter.xcframework',
      );
    });

    test('a current stamp without the Apple xcframeworks reinstalls', () async {
      writeStamp('9.9.9');

      await runner().run();
      expect(
        wrapCalls,
        hasLength(1),
        reason: 'a stamp alone must not skip the Apple install',
      );
    });

    test('a matching stamp with both xcframeworks present is up to date', () async {
      Directory(
        p.join(
          packageDir,
          'ios/typst_flutter/Binaries/typst_flutter.xcframework',
        ),
      ).createSync(recursive: true);
      Directory(
        p.join(
          packageDir,
          'macos/typst_flutter/Binaries/typst_flutter.xcframework',
        ),
      ).createSync(recursive: true);
      writeStamp('9.9.9');

      await runner().run();
      expect(wrapCalls, isEmpty);
    });

    test('a non-macOS host never asks for Apple artifacts', () async {
      final linuxRunner = SetupRunner(
        SetupOptions.parse(['--version', '9.9.9', '--no-verify']),
        httpGet: fakeGet,
        packageRoot: packageDir,
        hostPlatform: 'linux',
        createXcframework: ({required library, required output}) async =>
            wrapCalls.add((library: library, output: output)),
      );
      await linuxRunner.run();
      expect(wrapCalls, isEmpty);
      expect(Directory(p.join(packageDir, 'ios')).existsSync(), isFalse);
    });
  });
}
