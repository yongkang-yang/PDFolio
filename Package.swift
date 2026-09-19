// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PDFolio",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PDFolio", targets: ["PDFolio"])
    ],
    targets: [
        .target(
            name: "PDFolioCore",
            path: "Sources/PDFolioCore",
            linkerSettings: [
                .linkedFramework("PDFKit"),
                .linkedFramework("CoreGraphics")
            ]
        ),
        .executableTarget(
            name: "PDFolio",
            dependencies: ["PDFolioCore"],
            path: "Sources/PDFolio",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("PDFKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        // XCTest / swift-testing aren't usable with Command Line Tools alone,
        // so core checks and the large-document perf case run as a plain
        // executable: `swift run -c release pdfolio-checks`.
        .executableTarget(
            name: "pdfolio-checks",
            dependencies: ["PDFolioCore"],
            path: "Sources/PDFolioChecks"
        )
    ]
)
