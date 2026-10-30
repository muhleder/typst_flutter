import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// True when [path] is hand-written library code (the generated bridge under
/// `lib/src/rust/` legitimately imports `dart:ffi` behind a conditional
/// import). Separators are normalised because the directory walk yields
/// platform-native paths: on Windows they arrive as `lib\src\rust\...`.
bool isHandWrittenLibFile(String path) =>
    !path.replaceAll(r'\', '/').startsWith('lib/src/rust/');

/// True when [source] imports `dart:io` or `dart:ffi`.
bool importsPlatformOnlyLibrary(String source) =>
    RegExp(r'''import\s+'dart:(io|ffi)''').hasMatch(source);

void main() {
  group('isHandWrittenLibFile', () {
    test('accepts either separator style', () {
      expect(isHandWrittenLibFile('lib/src/compiler.dart'), isTrue);
      expect(isHandWrittenLibFile(r'lib\src\compiler.dart'), isTrue);
      expect(
        isHandWrittenLibFile('lib/src/rust/frb_generated.io.dart'),
        isFalse,
      );
      expect(
        isHandWrittenLibFile(r'lib\src\rust\frb_generated.io.dart'),
        isFalse,
      );
    });
  });

  test('lib/ never imports dart:io or dart:ffi', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (!isHandWrittenLibFile(entity.path)) continue;
      if (importsPlatformOnlyLibrary(entity.readAsStringSync())) {
        offenders.add(entity.path);
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'These files make the package unable to build for web: $offenders',
    );
  });
}
