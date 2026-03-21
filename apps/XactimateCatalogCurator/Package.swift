// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XactimateCatalogCurator",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "XactimateCatalogCurator",
            targets: ["XactimateCatalogCurator"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/CoreOffice/CoreXLSX.git", from: "0.14.1")
    ],
    targets: [
        .executableTarget(
            name: "XactimateCatalogCurator",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "CoreXLSX"
            ]
        ),
        .testTarget(
            name: "XactimateCatalogCuratorTests",
            dependencies: ["XactimateCatalogCurator"]
        )
    ]
)

