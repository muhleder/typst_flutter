#include <stdint.h>

// Mirrors the function the old podspec shipped: a link-time marker for the
// statically linked Rust library.
int32_t typst_flutter_dummy_method_to_enforce_bundling(void);
