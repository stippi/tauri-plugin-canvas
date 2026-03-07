// swift-tools-version:5.3

import PackageDescription

let package = Package(
    name: "tauri-plugin-canvas",
    platforms: [
        .macOS(.v10_13),
        .iOS(.v13),
    ],
    products: [
        .library(
            name: "tauri-plugin-canvas",
            type: .static,
            targets: ["tauri-plugin-canvas"]
        ),
    ],
    dependencies: [
        .package(name: "Tauri", path: "../.tauri/tauri-api")
    ],
    targets: [
        .target(
            name: "tauri-plugin-canvas",
            dependencies: [.byName(name: "Tauri")],
            path: "Sources"
        )
    ]
)
