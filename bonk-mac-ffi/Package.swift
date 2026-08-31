// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "BonkCoreFFI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BonkCoreFFI", targets: ["BonkCoreFFI"]),
    ],
    targets: [
        // Prebuilt Rust staticlib is linked here.
        // Build Rust first: `cargo build --manifest-path ../bonk-core/Cargo.toml --release`
        .target(
            name: "BonkCoreFFI",
            dependencies: ["BonkCoreBin"],
            path: "Sources/BonkCoreFFI"
        ),
        // Binary target - update path after building Rust core
        .binaryTarget(
            name: "BonkCoreBin",
            path: "../bonk-core/target/release/libbonk_core.a"
        ),
        .testTarget(name: "BonkCoreFFITests", dependencies: ["BonkCoreFFI"]),
    ]
)

// NOTE: For local dev without prebuilt lib, replace binaryTarget with:
// .systemLibrary(name: "BonkCoreBin", path: "Sources/CBonkCore", pkgConfig: "bonk_core")
