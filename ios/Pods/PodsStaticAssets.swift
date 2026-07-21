import Foundation

struct PodsStaticAssets {
    let root: URL

    init?(root: URL) {
        let root = root.standardizedFileURL
        if let validationError = Self.bundleGraphValidationError(root: root) {
            PodsDebugLog("Static asset bundle rejected: \(validationError)")
            return nil
        }
        self.root = root
    }

    // The app fetches only its loopback API. Podcast artwork and the browser audio
    // fallback may use publisher HTTP(S) URLs; native iPhone playback is bridged.
    static let contentSecurityPolicy = [
        "default-src 'none'",
        "base-uri 'none'",
        "object-src 'none'",
        "frame-src 'none'",
        "frame-ancestors 'none'",
        "form-action 'none'",
        "script-src 'self'",
        "script-src-attr 'none'",
        "style-src 'self'",
        "style-src-attr 'unsafe-inline'",
        "img-src 'self' http: https: data: blob:",
        "media-src 'self' http: https: blob:",
        "connect-src 'self'",
        "manifest-src 'self'"
    ].joined(separator: "; ")

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
        guard isInsideRoot(url), Self.isRegularFile(url) else {
            if !URL(fileURLWithPath: relativePath).pathExtension.isEmpty {
                PodsDebugLog("Static asset missing path=\(request.path) normalized=\(relativePath)")
                return HTTPResponse(
                    statusCode: 404,
                    headers: [
                        "content-type": "text/plain; charset=utf-8",
                        "content-security-policy": Self.contentSecurityPolicy,
                        "cache-control": "no-store, max-age=0",
                        "pragma": "no-cache"
                    ],
                    body: request.method == "HEAD" ? Data() : Data("Not Found".utf8)
                )
            }
            PodsDebugLog("Static asset fallback path=\(request.path) normalized=\(relativePath)")
            return fileResponse(
                root.appendingPathComponent("index.html"),
                includeBody: request.method != "HEAD"
            )
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
        Self.isInside(url, root: root)
    }

    private static func bundleGraphValidationError(root: URL) -> String? {
        let indexURL = root.appendingPathComponent("index.html", isDirectory: false)
        guard isRegularFile(indexURL) else {
            return "missing index.html at \(indexURL.path)"
        }
        guard let html = try? String(contentsOf: indexURL, encoding: .utf8) else {
            return "unreadable index.html at \(indexURL.path)"
        }

        let pattern = #"(?i)\b(?:src|href)\s*=\s*(["'])(.*?)\1"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return "could not inspect index.html references"
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        for match in expression.matches(in: html, range: range) {
            guard
                let referenceRange = Range(match.range(at: 2), in: html),
                let relativePath = localAssetPath(String(html[referenceRange]))
            else {
                continue
            }
            let assetURL = root.appendingPathComponent(relativePath, isDirectory: false).standardizedFileURL
            guard isInside(assetURL, root: root), isRegularFile(assetURL) else {
                return "missing referenced asset \(relativePath)"
            }
        }
        return nil
    }

    private static func localAssetPath(_ reference: String) -> String? {
        let value = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("#"), !value.hasPrefix("//") else {
            return nil
        }
        if URLComponents(string: value)?.scheme != nil {
            return nil
        }
        guard let path = URLComponents(string: value)?.path, !path.isEmpty else {
            return nil
        }
        let decoded = path.removingPercentEncoding ?? path
        return decoded.hasPrefix("/") ? String(decoded.dropFirst()) : decoded
    }

    private static func isInside(_ url: URL, root: URL) -> Bool {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
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
                "content-security-policy": Self.contentSecurityPolicy,
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
