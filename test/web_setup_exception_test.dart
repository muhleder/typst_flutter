import 'package:flutter_test/flutter_test.dart';
import 'package:typst_flutter/typst_flutter.dart';

void main() {
  group('describeInitFailure', () {
    test('reports a stale wasm bundle as an outdated setup, with the fix', () {
      final error = describeInitFailure(
        StateError(
          'The content hash of the Dart code and the Rust code does not match',
        ),
      );

      expect(error, isA<TypstWebSetupException>());
      expect(error.message, contains('stale'));
      expect(error.message, contains('dart run typst_flutter:setup --web'));
    });

    test('reports a codegen version mismatch as a stale bundle', () {
      final error = describeInitFailure(
        Exception('Please run flutter_rust_bridge_codegen generate'),
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
