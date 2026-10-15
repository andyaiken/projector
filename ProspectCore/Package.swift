// swift-tools-version: 6.2

import PackageDescription

// ProspectCore is the show model: everything that can be worked out without
// a window. No AppKit, so it can be tested against recorded outputs on its
// own.
//
// ProspectStage is the renderers: Core Text and Core Animation layer trees
// that paint cues into surfaces. It knows nothing about windows, so it can be
// tested headlessly too.
let package = Package(
    name: "ProspectCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ProspectCore", targets: ["ProspectCore"]),
        .library(name: "ProspectStage", targets: ["ProspectStage"]),
    ],
    targets: [
        .target(name: "ProspectCore"),
        .target(name: "ProspectStage", dependencies: ["ProspectCore"]),
        .testTarget(
            name: "ProspectCoreTests",
            dependencies: ["ProspectCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "ProspectStageTests", dependencies: ["ProspectStage"]),
    ]
)
