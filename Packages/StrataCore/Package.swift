// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StrataCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(name: "StrataCore", targets: ["StrataCore"]),
        .executable(name: "inspect-scan", targets: ["InspectScan"]),
        .executable(name: "validate-benchmark", targets: ["ValidateBenchmark"]),
        .executable(name: "evaluate-benchmark", targets: ["EvaluateBenchmark"]),
        .executable(name: "assess-baseline", targets: ["AssessBaseline"]),
        .executable(name: "intake-baseline", targets: ["IntakeBaseline"]),
        .executable(name: "import-public-rgbd", targets: ["ImportPublicRGBD"]),
        .executable(name: "reconstruct-public-rgbd", targets: ["ReconstructPublicRGBD"]),
        .executable(name: "sweep-public-rgbd", targets: ["SweepPublicRGBD"]),
        .executable(name: "localize-benchmark-residuals", targets: ["LocalizeBenchmarkResiduals"]),
        .executable(name: "verify-saved-surface", targets: ["VerifySavedSurface"])
    ],
    targets: [
        .target(
            name: "StrataCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(name: "InspectScan", dependencies: ["StrataCore"]),
        .executableTarget(name: "ValidateBenchmark", dependencies: ["StrataCore"]),
        .executableTarget(name: "EvaluateBenchmark", dependencies: ["StrataCore"]),
        .executableTarget(name: "AssessBaseline", dependencies: ["StrataCore"]),
        .executableTarget(name: "IntakeBaseline", dependencies: ["StrataCore"]),
        .executableTarget(name: "ImportPublicRGBD", dependencies: ["StrataCore"]),
        .executableTarget(name: "ReconstructPublicRGBD", dependencies: ["StrataCore"]),
        .executableTarget(name: "SweepPublicRGBD", dependencies: ["StrataCore"]),
        .executableTarget(name: "LocalizeBenchmarkResiduals", dependencies: ["StrataCore"]),
        .executableTarget(name: "VerifySavedSurface", dependencies: ["StrataCore"]),
        .testTarget(
            name: "StrataCoreTests",
            dependencies: ["StrataCore"]
        )
    ]
)
