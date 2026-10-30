import 'package:flutter_test/flutter_test.dart';
import 'package:typst_flutter/typst_flutter.dart';

void main() {
  group('describeInitFailure', () {
    test('reports a stale wasm bundle as an outdated setup, with the fix', () {
      // The message flutter_rust_bridge 2.14.0-beta.2 really throws
      // (main_components/entrypoint.dart:138).
      final error = describeInitFailure(
        StateError(
          'Content hash on Dart side (-724385650) is different from Rust side '
          '(1234), indicating out-of-sync code.',
        ),
      );

      expect(error, isA<TypstWebSetupException>());
      expect(error.message, contains('stale'));
      expect(error.message, contains('dart run typst_flutter:setup --web'));
    });

    test('reports a codegen version mismatch as a stale bundle', () {
      // main_components/entrypoint.dart:115
      final error = describeInitFailure(
        StateError(
          "RustLib's codegen version (2.14.0-beta.2) should be the same as "
          'runtime version (2.13.0).',
        ),
      );

      expect(error.message, contains('stale'));
    });

    test('explains the cross-origin headers for any other failure', () {
      final error = describeInitFailure(Exception('WebAssembly.Memory'));

      expect(error.message, contains('Cross-Origin-Opener-Policy'));
      expect(error.message, contains('Cross-Origin-Embedder-Policy'));
    });

    test('keeps the original error for debugging', () {
      final cause = Exception('boom');

      final error = describeInitFailure(cause);

      expect(error.cause, same(cause));
    });
  });

  test('TypstWebSetupException names itself in toString', () {
    const error = TypstWebSetupException('run setup', cause: 'because');

    expect(error.toString(), contains('TypstWebSetupException'));
    expect(error.toString(), contains('run setup'));
    expect(error.toString(), contains('because'));
  });
}
