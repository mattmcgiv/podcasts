#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

cat > "$TMP/main.swift" <<'SWIFT'
import Foundation

struct HTTPRequest {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data

    init(method: String, target: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method.uppercased()
        self.target = target
        self.headers = headers
        self.body = body
    }

    var path: String {
        URLComponents(string: "http://localhost\(target)")?.path ?? target
    }
}

struct HTTPResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

func PodsDebugLog(_ message: @autoclosure () -> String) {}

enum RegressionFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw RegressionFailure.failed(message) }
}

func makeDirectory(_ name: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("PodsStaticAssets-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

func write(_ contents: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(contents.utf8).write(to: url)
}

let missingIndexRoot = try makeDirectory("missing-index")
let missingIndexAssets: PodsStaticAssets? = PodsStaticAssets(root: missingIndexRoot)
try expect(missingIndexAssets == nil, "construction must reject a bundle without index.html")

let brokenGraphRoot = try makeDirectory("broken-graph")
try write(
    """
    <!doctype html>
    <link rel="stylesheet" href="./assets/app.css">
    <script type="module" src="./assets/missing.js"></script>
    """,
    to: brokenGraphRoot.appendingPathComponent("index.html")
)
try write("body {}", to: brokenGraphRoot.appendingPathComponent("assets/app.css"))
let brokenGraphAssets: PodsStaticAssets? = PodsStaticAssets(root: brokenGraphRoot)
try expect(brokenGraphAssets == nil, "construction must reject an index that references a missing local asset")

let validRoot = try makeDirectory("valid")
let indexMarker = "<main>static-assets-regression-shell</main>"
try write(
    """
    <!doctype html>
    <link rel="stylesheet" href="./assets/app.css?build=1">
    <link rel="manifest" href="./manifest.webmanifest">
    <script type="module" src="./assets/app.js#entry"></script>
    \(indexMarker)
    """,
    to: validRoot.appendingPathComponent("index.html")
)
try write("body {}", to: validRoot.appendingPathComponent("assets/app.css"))
try write("document.body.dataset.ready = 'yes'", to: validRoot.appendingPathComponent("assets/app.js"))
try write("{}", to: validRoot.appendingPathComponent("manifest.webmanifest"))
let maybeAssets: PodsStaticAssets? = PodsStaticAssets(root: validRoot)
guard let assets = maybeAssets else {
    throw RegressionFailure.failed("construction must accept a complete local asset graph")
}

guard let missingFile = assets.response(for: HTTPRequest(method: "GET", target: "/assets/not-built.js")) else {
    throw RegressionFailure.failed("a missing file-extension request must be handled by static assets")
}
try expect(missingFile.statusCode == 404, "a missing file-extension asset must return 404, not index.html")
try expect(!String(decoding: missingFile.body, as: UTF8.self).contains(indexMarker), "a missing asset must not receive the SPA shell")

guard let route = assets.response(for: HTTPRequest(method: "GET", target: "/shows/42")) else {
    throw RegressionFailure.failed("an extensionless client route must be handled by static assets")
}
try expect(route.statusCode == 200, "an extensionless client route must retain the SPA fallback")
try expect(String(decoding: route.body, as: UTF8.self).contains(indexMarker), "the SPA fallback must serve index.html")

guard let headRoute = assets.response(for: HTTPRequest(method: "HEAD", target: "/shows/42")) else {
    throw RegressionFailure.failed("an extensionless HEAD route must be handled by static assets")
}
try expect(headRoute.statusCode == 200, "an extensionless HEAD route must retain the SPA fallback")
try expect(headRoute.body.isEmpty, "a HEAD SPA fallback must not include the index.html body")

let outsideRoot = try makeDirectory("outside")
try write("private", to: outsideRoot.appendingPathComponent("secret.js"))
try FileManager.default.createSymbolicLink(
    at: validRoot.appendingPathComponent("escape", isDirectory: true),
    withDestinationURL: outsideRoot
)
guard let escapedAsset = assets.response(for: HTTPRequest(method: "GET", target: "/escape/secret.js")) else {
    throw RegressionFailure.failed("a file-extension path through a symlink must be handled as missing")
}
try expect(escapedAsset.statusCode == 404, "static assets must not follow symlinks outside their root")
try expect(String(decoding: escapedAsset.body, as: UTF8.self) != "private", "an escaped file must never be served")

print("static asset regression tests passed")
SWIFT

xcrun swiftc \
  "$ROOT/ios/Pods/PodsStaticAssets.swift" \
  "$TMP/main.swift" \
  -o "$TMP/static-assets-test"
"$TMP/static-assets-test"
