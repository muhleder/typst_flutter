import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:typst_flutter/src/setup/setup_options.dart';

void main() {
  group('SetupOptions.parse', () {
    test('--web opt-in and never implied', () {
      expect(SetupOptions.parse(['--web']).includeWeb, isTrue);
      expect(SetupOptions.parse([]).includeWeb, isFalse);
    });

    test('keeps the existing flags independent of --web', () {
      final options = SetupOptions.parse([
        '--web',
        '--force',
        '--no-verify',
        '--all-platforms',
        '--version',
        '9.9.9',
      ]);

      expect(options.includeWeb, isTrue);
      expect(options.force, isTrue);
      expect(options.noVerify, isTrue);
      expect(options.allPlatforms, isTrue);
      expect(options.version, '9.9.9');
    });

    test('--version= form is accepted', () {
      expect(SetupOptions.parse(['--version=1.2.3']).version, '1.2.3');
    });
  });

  group('RepositorySlug', () {
    test('parses an owner/name pair', () {
      final slug = RepositorySlug.parse('muhleder/typst_flutter');

      expect(slug?.owner, 'muhleder');
      expect(slug?.name, 'typst_flutter');
    });

    test('derives the slug from the pubspec repository url', () {
      final slug = RepositorySlug.fromRepositoryUrl(
        'https://github.com/muhleder/typst_flutter.git',
      );

      expect(slug?.owner, 'muhleder');
      expect(slug?.name, 'typst_flutter');
    });

    test('tolerates a trailing slash', () {
      expect(
        RepositorySlug.fromRepositoryUrl(
          'https://github.com/muhleder/typst_flutter/',
        )?.name,
        'typst_flutter',
      );
    });

    test('returns null for a url it cannot read, so callers can fall back', () {
      expect(RepositorySlug.fromRepositoryUrl(''), isNull);
      expect(RepositorySlug.fromRepositoryUrl('not a url'), isNull);
      expect(RepositorySlug.parse('just-a-name'), isNull);
    });
  });

  test('--repo overrides the release repository', () {
    final options = SetupOptions.parse(['--web', '--repo', 'muhleder/my-fork']);

    expect(options.repo?.owner, 'muhleder');
    expect(options.repo?.name, 'my-fork');
  });

  test('web artifacts land in <cwd>/web/pkg, not in the package root', () {
    final options = SetupOptions.parse(['--web']);

    expect(
      options.webDestinationFor('/tmp/app'),
      p.join('/tmp/app', 'web', 'pkg'),
    );
  });

  group('webEntryPath', () {
    final options = SetupOptions.parse(['--web']);

    test('strips the pkg/ prefix the tarball uses', () {
      expect(
        options.webEntryPath('pkg/typst_flutter_bg.wasm'),
        'typst_flutter_bg.wasm',
      );
    });

    test('keeps nested paths and accepts a prefixless entry', () {
      expect(options.webEntryPath('pkg/icons/x.png'), 'icons/x.png');
      expect(options.webEntryPath('typst_flutter.js'), 'typst_flutter.js');
    });

    test('rejects path traversal', () {
      expect(options.webEntryPath('pkg/../../etc/passwd'), isNull);
      expect(options.webEntryPath('/etc/passwd'), isNull);
    });
  });

  test('the web version stamp is separate from the native one', () {
    final options = SetupOptions.parse(['--web']);

    expect(
      options.webVersionStampFor('/tmp/app'),
      p.join('/tmp/app', 'web', 'pkg', '.typst_flutter_web_version'),
    );
  });
}
