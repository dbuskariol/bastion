// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Bastion",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "bastion", targets: ["bastion"]),
        .executable(name: "BastionMenuBar", targets: ["BastionMenuBar"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", .upToNextMajor(from: "2.9.1"))
    ],
    targets: [
        .target(name: "BastionIdentifiers"),
        .target(
            name: "BastionCore",
            dependencies: ["BastionIdentifiers"]
        ),
        .executableTarget(
            name: "bastion",
            dependencies: ["BastionIdentifiers", "BastionCore"]
        ),
        .executableTarget(
            name: "BastionMenuBar",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                "BastionIdentifiers",
                "BastionCore"
            ]
        ),
        .testTarget(
            name: "BastionCoreTests",
            dependencies: ["BastionCore", "BastionIdentifiers"],
            resources: [.copy("Fixtures")],
            swiftSettings: [
                // CLT-only environments ship swift-testing in
                // /Library/Developer/CommandLineTools/Library/Developer/Frameworks/
                // but SPM doesn't add it to the framework search path
                // automatically. Without -F here, `import Testing` fails
                // even though the framework is on disk.
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
                ])
            ]
        )
    ]
)
