import CryptoKit
import Foundation

protocol PodcastDirectorySearching {
    var isConfigured: Bool { get }

    func search(query: String) async throws -> [DirectoryPodcast]
}

protocol PersonAppearanceSearching {
    func searchAppearances(person: String) async throws -> [DirectoryAppearance]
}

struct DisabledPodcastDirectorySearcher: PodcastDirectorySearching {
    var isConfigured: Bool {
        false
    }

    func search(query: String) async throws -> [DirectoryPodcast] {
        []
    }
}

struct PodcastIndexClient: PodcastDirectorySearching, PersonAppearanceSearching {
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

    private struct PersonSearchResponse: Decodable {
        let items: [PersonSearchItem]
    }

    private struct PersonSearchItem: Decodable {
        let id: Int64?
        let guid: String?
        let title: String?
        let description: String?
        let datePublished: Int64?
        let duration: Int64?
        let enclosureUrl: String?
        let image: String?
        let feedUrl: String?
        let feedTitle: String?
        let feedImage: String?
        let persons: [Person]?
    }

    private struct Person: Decodable {
        let name: String?
        let role: String?
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

    func searchAppearances(person: String) async throws -> [DirectoryAppearance] {
        let items: PersonSearchResponse = try await get("search/byperson", queryItems: [
            URLQueryItem(name: "q", value: person),
            URLQueryItem(name: "max", value: "100"),
            URLQueryItem(name: "fulltext", value: nil),
        ])
        let normalizedPerson = normalized(person)
        return items.items.compactMap { item in
            guard let feedURL = nonEmpty(item.feedUrl),
                  let audioURL = nonEmpty(item.enclosureUrl),
                  let guid = nonEmpty(item.guid) ?? item.id.map(String.init),
                  let key = item.id.map(String.init) ?? nonEmpty(item.guid) else {
                return nil
            }
            let title = item.title ?? ""
            let description = item.description ?? ""
            let personTag = item.persons?.first { normalized($0.name ?? "") == normalizedPerson }
            let titleHasName = normalized(title).contains(normalizedPerson)
            let descriptionHasName = normalized(description).contains(normalizedPerson)
            let confidence: String
            let evidence: String
            if let personTag {
                confidence = "high"
                evidence = "person tag" + (personTag.role.map { ": \($0)" } ?? "")
            } else if titleHasName && descriptionHasName {
                confidence = "high"
                evidence = "name in title and description"
            } else if titleHasName || descriptionHasName {
                confidence = "review"
                evidence = titleHasName ? "name in title" : "name in description"
            } else {
                return nil
            }
            return DirectoryAppearance(
                source_episode_key: key,
                feed_url: feedURL,
                feed_title: item.feedTitle ?? "",
                feed_image_url: item.feedImage ?? "",
                guid: guid,
                title: title,
                description: description,
                audio_url: audioURL,
                duration_secs: item.duration,
                published_at: item.datePublished ?? 0,
                image_url: item.image ?? "",
                evidence: evidence,
                confidence: confidence
            )
        }
    }

    private func get<T: Decodable>(_ path: String, queryItems: [URLQueryItem]) async throws -> T {
        var endpoint = baseURL
        endpoint.appendPathComponent(path)
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw PodsBackendError.upstream("invalid Podcast Index URL")
        }
        components.queryItems = queryItems
        guard let url = components.url else { throw PodsBackendError.upstream("invalid Podcast Index URL") }
        var request = URLRequest(url: url)
        let now = Int64(Date().timeIntervalSince1970)
        request.setValue(String(now), forHTTPHeaderField: "X-Auth-Date")
        request.setValue(key, forHTTPHeaderField: "X-Auth-Key")
        request.setValue(Self.authHeader(key: key, secret: secret, timestamp: now), forHTTPHeaderField: "Authorization")
        request.setValue("Pods/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw PodsBackendError.upstream("Podcast Index request failed")
        }
        return try JSONDecoder().decode(T.self, from: data)
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

private func normalized(_ value: String) -> String {
    value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .lowercased()
        .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        .joined(separator: " ")
}
