import 'package:flutter_test/flutter_test.dart';

import '../bin/setup.dart';

void main() {
  group('parseLipoArchitectures', () {
    test('reads a fat library', () {
      expect(
        parseLipoArchitectures(
          'Architectures in the fat file: libtypst_flutter.a are: x86_64 arm64',
        ),
        {'x86_64', 'arm64'},
      );
    });

    test('reads a thin library', () {
      expect(
        parseLipoArchitectures(
          'Non-fat file: libtypst_flutter.a is architecture: arm64',
        ),
        {'arm64'},
      );
    });

    test('reads nothing from unparseable output', () {
      expect(parseLipoArchitectures(''), isEmpty);
    });
  });

  group('macosArchitectureWarning', () {
    test('stays quiet when both arches are present', () {
      expect(macosArchitectureWarning({'arm64', 'x86_64'}), isNull);
    });

    test('names just build-host when an arch is missing', () {
      final warning = macosArchitectureWarning({'arm64'});
      expect(warning, isNotNull);
      expect(warning, contains('just build-host'));
      expect(warning, contains('x86_64'));
    });

    test('warns when the architectures are unknown', () {
      expect(
        macosArchitectureWarning(const <String>{}),
        contains('just build-host'),
      );
    });
  });

  group('xcodebuildCreateXcframework', () {
    test('explains a missing xcodebuild', () async {
      await expectLater(
        xcodebuildCreateXcframework(
          library: '/tmp/does-not-exist.a',
          output: '/tmp/does-not-matter.xcframework',
          executable: 'definitely-not-xcodebuild',
        ),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('xcodebuild'), contains('Xcode')),
          ),
        ),
      );
    });
  });
}
