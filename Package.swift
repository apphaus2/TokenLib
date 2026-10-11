// swift-tools-version:5.9
import PackageDescription

// TokenLib: token management for apps that use AI models. The manifest stays at the
// repository root so the package can be added by URL; sources live in ios/ next to android/.
// SQLite comes with every Apple SDK (sqlite3.h and libsqlite3.tbd), so the system library must
// not consult pkg-config there: a Homebrew sqlite would answer for the macOS host and drag its
// macOS dylib into iOS, tvOS and watchOS link lines. Linux has no SDK copy, so it asks pkg-config.
#if os(Linux)
let csqlite: Target = .systemLibrary(name: "CSQLite", path: "ios/Sources/CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"])])
#else
let csqlite: Target = .systemLibrary(name: "CSQLite", path: "ios/Sources/CSQLite")
#endif

let package = Package(
    name: "TokenLib",
    platforms: [.iOS(.v15), .macOS(.v12), .tvOS(.v15), .watchOS(.v8)],
    products: [
        // The library: providers, catalog, profiles, repositories (SQLite), the server and the client. Pure Foundation.
        .library(name: "TokenLib", targets: ["TokenLib"]),
        // Apple platforms: the Keychain cipher, the `TokenLibBootstrap.standard` bootstrap and the observable TokenLibModel.
        .library(name: "TokenLibApple", targets: ["TokenLibApple"]),
        // SwiftUI pieces a host app embeds: the settings section, the usage view, the status badge.
        .library(name: "TokenLibUI", targets: ["TokenLibUI"]),
    ],
    targets: [
        csqlite,
        .target(name: "TokenLib", dependencies: ["CSQLite"], path: "ios/Sources/TokenLib"),
        .target(name: "TokenLibApple", dependencies: ["TokenLib"], path: "ios/Sources/TokenLibApple"),
        .target(name: "TokenLibUI", dependencies: ["TokenLib", "TokenLibApple"], path: "ios/Sources/TokenLibUI"),
        .testTarget(name: "TokenLibTests", dependencies: ["TokenLib"], path: "ios/Tests/TokenLibTests"),
    ]
)
