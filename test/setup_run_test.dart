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
}
