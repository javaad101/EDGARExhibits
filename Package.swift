// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EDGARExhibits",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "EDGARExhibits", targets: ["EDGARExhibits"])
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/googleapis/swift-google-cloud-storage.git", from: "0.7.0")
    ],
    targets: [
        .executableTarget(
            name: "EDGARExhibits",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "GoogleCloudStorage", package: "swift-google-cloud-storage")
            ]
        ),
        .testTarget(
            name: "EDGARExhibitsTests",
            dependencies: ["EDGARExhibits"]
        )
    ]
)
