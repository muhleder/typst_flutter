#include <stdint.h>

// SwiftPM requires at least one source file in a target. This mirrors the
// function the old podspec shipped so the plugin keeps a link-time marker.
int32_t typst_flutter_dummy_method_to_enforce_bundling(void) {
    return 0;
}
