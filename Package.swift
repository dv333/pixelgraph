// swift-tools-version: 6.2
import PackageDescription

// The Info.plist is embedded in the binary so macOS can show the
// Photos permission prompt for a plain command-line tool.
let infoPlist = Context.packageDirectory + "/Support/Info.plist"

let package = Package(
    name: "pixelgraph",
    platforms: [.macOS("27.0")],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "pixelgraph",
            dependencies: [.product(name: "ArgumentParser", package: "swift-argument-parser")],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                              "-Xlinker", "__info_plist", "-Xlinker", infoPlist]),
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(name: "PixelGraphTests", dependencies: ["pixelgraph"]),
    ]
)
