import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:typst_flutter/src/bridge/bridge_io.dart';

void main() {
  test('Apple platforms load symbols from the process image', () {
    expect(usesProcessLibrary(TargetPlatform.iOS), isTrue);
    expect(usesProcessLibrary(TargetPlatform.macOS), isTrue);
  });

  test("other platforms keep flutter_rust_bridge's file loader", () {
    for (final platform in const [
      TargetPlatform.android,
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.fuchsia,
    ]) {
      expect(usesProcessLibrary(platform), isFalse, reason: '$platform');
    }
  });
}
