// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TFLab",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "TFLab", targets: ["TFLab"]),
    ],
    targets: [
        .target(name: "TFLab"),
    ]
)
