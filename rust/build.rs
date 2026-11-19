fn main() {
    // Capture the version of the `typst` dependency from Cargo.toml
    let toml_content = std::fs::read_to_string("Cargo.toml").expect("Failed to read Cargo.toml");
    let typst_version = toml_content
        .lines()
        .find(|line| line.trim().starts_with("typst ="))
        .and_then(|line| line.split('"').nth(1))
        .expect("Could not find typst version in Cargo.toml");

    println!("cargo:rustc-env=TYPST_VERSION={}", typst_version);

    emit_android_page_size_flags();
}

/// Links every Android library for 16 KB memory pages.
///
/// Android 15 and newer can run devices with a 16 KB page size, and Play
/// requires every 64-bit native library an app ships to load there. The loader
/// maps each `PT_LOAD` segment at the page size and needs the segment file
/// offsets to agree with their virtual addresses modulo that size, so the
/// library has to be linked for it; the NDK's default is 4 KB, which produces a
/// library Play refuses with "Libraries that do not support 16 KB".
///
/// The flags come from the build script rather than a `.cargo/config.toml` so
/// they travel with the crate: `cross`, `cargo ndk`, Cargokit and a plain
/// `cargo build` all link the cdylib through this script, whatever directory
/// they are run from, and none of them needs the right linker invocation
/// remembered. `max-page-size` aligns the segments, `common-page-size` the
/// sections inside them, and both are what NDK r28 and later do by default.
/// 16 KB alignment costs a few KB of padding, which is why it is asked of the
/// 32-bit ABIs too: the build has one rule, and no 4 KB library can leak into a
/// release by being built for an ABI Play does not check.
fn emit_android_page_size_flags() {
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if target_os != "android" {
        return;
    }

    for arg in [
        "-Wl,-z,max-page-size=16384",
        "-Wl,-z,common-page-size=16384",
    ] {
        println!("cargo:rustc-link-arg={arg}");
    }
}
