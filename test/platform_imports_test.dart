import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('lib/ never imports dart:io or dart:ffi', () {
    final offenders = <String>[];
    final pattern = RegExp(r'''import\s+'dart:(io|ffi)''');

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      // Generated bridge code: the .io variant is only imported on native
      // platforms through a conditional import, so it may use dart:ffi.
      if (entity.path.startsWith('lib/src/rust/')) continue;
      if (pattern.hasMatch(entity.readAsStringSync())) {
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
