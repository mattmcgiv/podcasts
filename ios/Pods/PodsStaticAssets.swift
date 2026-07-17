import Foundation

struct PodsStaticAssets {
    let root: URL

    static func bundled(bundle: Bundle = .main) -> PodsStaticAssets? {
        guard let index = bundle.url(forResource: "index", withExtension: "html", subdirectory: "Web") else {
            PodsDebugLog("Bundled static assets missing Web/index.html")
            return nil
        }
        PodsDebugLog("Bundled static assets root=\(index.deletingLastPathComponent().path)")
        return PodsStaticAssets(root: index.deletingLastPathComponent())
    }

    func response(for request: HTTPRequest) -> HTTPResponse? {
        guard request.method == "GET" || request.method == "HEAD" else {
            return nil
        }
        guard !request.path.hasPrefix("/api") else {
            return nil
        }

        let relativePath = normalizedPath(request.path)
        let url = root.appendingPathComponent(relativePath, isDirectory: false)
        guard isInsideRoot(url), FileManager.default.fileExists(atPath: url.path) else {
            PodsDebugLog("Static asset fallback path=\(request.path) normalized=\(relativePath)")
            return fileResponse(root.appendingPathComponent("index.html"))
        }
        PodsDebugLog("Static asset serving path=\(request.path) normalized=\(relativePath)")
        return fileResponse(url, includeBody: request.method != "HEAD")
    }

    private func normalizedPath(_ rawPath: String) -> String {
        var path = rawPath
        if path == "/" || path.isEmpty {
            return "index.html"
        }
        if path.hasPrefix("/") {
            path.removeFirst()
        }
        let decoded = path.removingPercentEncoding ?? path
        let parts = decoded.split(separator: "/").filter { part in
            part != "." && part != ".." && !part.isEmpty
        }
        return parts.joined(separator: "/")
    }

    private func isInsideRoot(_ url: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private func fileResponse(_ url: URL, includeBody: Bool = true) -> HTTPResponse? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        let body = includeBody ? data : Data()
        return HTTPResponse(
            statusCode: 200,
            headers: [
                "content-type": contentType(for: url.pathExtension),
                "cache-control": "no-store, max-age=0",
                "pragma": "no-cache"
            ],
            body: body
        )
    }

    private func contentType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html":
            return "text/html; charset=utf-8"
        case "js":
            return "text/javascript; charset=utf-8"
        case "css":
            return "text/css; charset=utf-8"
        case "json", "webmanifest":
            return "application/manifest+json; charset=utf-8"
        case "svg":
            return "image/svg+xml"
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        default:
            return "application/octet-stream"
        }
    }
}
