// swift-tools-version: 5.9
// SwiftPM manifest for typst_flutter (ios).
//
// The Rust static library is installed as the binary target by
// `dart run typst_flutter:setup`, which writes
// Binaries/typst_flutter.xcframework inside this package. SwiftPM maps a
// binary target to an artifact of the same name, so the binary target is
// `typst_flutter` (matching typst_flutter.xcframework) and the source target
// carries the plugin suffix.
import PackageDescription

let package = Package(
    name: "typst_flutter",
    platforms: [.iOS("13.0")],
    products: [
        .library(name: "typst-flutter", targets: ["typst_flutter_plugin"]),
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
    ],
    targets: [
        .target(
            name: "typst_flutter_plugin",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .target(name: "typst_flutter"),
            ],
            linkerSettings: [
                // SwiftPM's replacement for the podspec's -force_load.
                // flutter_rust_bridge resolves its symbols at runtime via
                // DynamicLibrary.process(), and the Rust crate is a single
                // codegen unit under fat LTO, so forcing this one symbol keeps
                // every frb_* entry point (and all of Typst) in the app binary.
                .unsafeFlags(["-Wl,-u", "-Wl,_frb_get_rust_content_hash"]),
            ]
        ),
        .binaryTarget(
            name: "typst_flutter",
            path: "Binaries/typst_flutter.xcframework"
        ),
    ]
)
