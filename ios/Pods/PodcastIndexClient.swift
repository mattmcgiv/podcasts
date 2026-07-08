import CryptoKit
import Foundation

protocol PodcastDirectorySearching {
    var isConfigured: Bool { get }

    func search(query: String) async throws -> [DirectoryPodcast]
}

struct DisabledPodcastDirectorySearcher: PodcastDirectorySearching {
    var isConfigured: Bool {
        false
    }

    func search(query: String) async throws -> [DirectoryPodcast] {
        []
    }
}

struct PodcastIndexClient: PodcastDirectorySearching {
    private struct SearchResponse: Decodable {
        let feeds: [Feed]
    }

    private struct Feed: Decodable {
        let title: String?
        let url: String?
        let author: String?
        let description: String?
        let image: String?
        let artwork: String?
    }

    private let key: String
    private let secret: String
    private let baseURL: URL
    private let session: URLSession

    var isConfigured: Bool {
        true
    }

    init(key: String, secret: String, baseURL: URL, session: URLSession = .shared) {
        self.key = key
        self.secret = secret
        self.baseURL = baseURL
        self.session = session
    }

    static func fromBundle(_ bundle: Bundle = .main) -> PodcastIndexClient? {
        guard let url = bundle.url(forResource: "PodcastIndexCredentials", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let rawValues = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }

        let key = stringValue(rawValues["PODCASTINDEX_KEY"])
        let secret = stringValue(rawValues["PODCASTINDEX_SECRET"])
        guard !key.isEmpty, !secret.isEmpty else {
            return nil
        }

        let baseURL = URL(string: stringValue(rawValues["PODCASTINDEX_BASE_URL"]))
            ?? URL(string: "https://api.podcastindex.org/api/1.0")!
        return PodcastIndexClient(key: key, secret: secret, baseURL: baseURL)
    }

    func search(query: String) async throws -> [DirectoryPodcast] {
        var endpoint = baseURL
        endpoint.appendPathComponent("search/byterm")

        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw PodsBackendError.upstream("invalid Podcast Index URL")
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "max", value: "20")
        ]
        guard let url = components.url else {
            throw PodsBackendError.upstream("invalid Podcast Index search URL")
        }

        var request = URLRequest(url: url)
        let now = Int64(Date().timeIntervalSince1970)
        request.setValue(String(now), forHTTPHeaderField: "X-Auth-Date")
        request.setValue(key, forHTTPHeaderField: "X-Auth-Key")
        request.setValue(Self.authHeader(key: key, secret: secret, timestamp: now), forHTTPHeaderField: "Authorization")
        request.setValue("Pods/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PodsBackendError.upstream("Podcast Index returned a non-HTTP response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw PodsBackendError.upstream("Podcast Index returned HTTP \(httpResponse.statusCode)")
        }

        let body = try JSONDecoder().decode(SearchResponse.self, from: data)
        return body.feeds.compactMap { feed in
            guard let feedURL = feed.url?.trimmingCharacters(in: .whitespacesAndNewlines), !feedURL.isEmpty else {
                return nil
            }
            return DirectoryPodcast(
                title: feed.title ?? "",
                author: feed.author ?? "",
                feed_url: feedURL,
                image_url: nonEmpty(feed.artwork) ?? nonEmpty(feed.image) ?? "",
                description: feed.description ?? "",
                subscribed: false
            )
        }
    }

    static func authHeader(key: String, secret: String, timestamp: Int64) -> String {
        let value = "\(key)\(secret)\(timestamp)"
        let digest = Insecure.SHA1.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func stringValue(_ value: Any?) -> String {
        guard let value = value as? String else {
            return ""
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private func nonEmpty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return nil
    }
    return value
}
