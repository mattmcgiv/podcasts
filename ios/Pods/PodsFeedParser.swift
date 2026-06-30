import Foundation

struct ParsedFeed {
    struct Episode {
        var guid: String
        var title: String
        var notesHTML: String
        var audioURL: String
        var durationSecs: Int64?
        var publishedAt: Int64
        var imageURL: String
    }

    var title: String
    var description: String
    var imageURL: String
    var siteURL: String
    var episodes: [Episode]
}

protocol FeedFetching {
    func data(for url: URL) async throws -> Data
}

struct URLSessionFeedFetcher: FeedFetching {
    func data(for url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw PodsBackendError.upstream("feed returned HTTP \(http.statusCode)")
        }
        return data
    }
}

final class RSSParser: NSObject, XMLParserDelegate {
    private var channelTitle = ""
    private var channelDescription = ""
    private var channelLink = ""
    private var channelImageURL = ""
    private var currentText = ""
    private var currentElement = ""
    private var inItem = false
    private var inChannelImage = false
    private var currentItem = ParsedFeed.Episode(
        guid: "",
        title: "",
        notesHTML: "",
        audioURL: "",
        durationSecs: nil,
        publishedAt: 0,
        imageURL: ""
    )
    private var episodes: [ParsedFeed.Episode] = []

    static func parse(_ data: Data) throws -> ParsedFeed {
        let delegate = RSSParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw PodsBackendError.upstream(parser.parserError?.localizedDescription ?? "feed could not be parsed")
        }
        return ParsedFeed(
            title: delegate.channelTitle,
            description: delegate.channelDescription,
            imageURL: delegate.channelImageURL,
            siteURL: delegate.channelLink,
            episodes: delegate.episodes
        )
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName.lowercased()
        currentText = ""
        switch currentElement {
        case "item", "entry":
            inItem = true
            currentItem = ParsedFeed.Episode(
                guid: "",
                title: "",
                notesHTML: "",
                audioURL: "",
                durationSecs: nil,
                publishedAt: 0,
                imageURL: ""
            )
        case "enclosure" where inItem:
            if let url = attributeDict["url"], !url.isEmpty {
                let type = attributeDict["type"]?.lowercased() ?? ""
                if currentItem.audioURL.isEmpty || type.hasPrefix("audio/") {
                    currentItem.audioURL = url
                }
            }
        case "media:content" where inItem,
             "content" where inItem:
            if let url = attributeDict["url"], !url.isEmpty {
                let type = attributeDict["type"]?.lowercased() ?? ""
                if currentItem.audioURL.isEmpty || type.hasPrefix("audio/") {
                    currentItem.audioURL = url
                }
            }
        case "itunes:image" where inItem:
            if let href = attributeDict["href"], !href.isEmpty {
                currentItem.imageURL = href
            }
        case "itunes:image":
            if let href = attributeDict["href"], !href.isEmpty {
                channelImageURL = href
            }
        case "image":
            inChannelImage = !inItem
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.lowercased()
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            currentText = ""
            currentElement = ""
        }

        if inItem {
            switch name {
            case "title":
                currentItem.title = text
            case "guid", "id":
                currentItem.guid = text
            case "description", "summary", "content:encoded":
                if !text.isEmpty {
                    currentItem.notesHTML = text
                }
            case "pubdate", "published", "updated":
                currentItem.publishedAt = parseFeedDate(text)
            case "itunes:duration", "duration":
                currentItem.durationSecs = parseDuration(text)
            case "media:thumbnail":
                break
            case "item", "entry":
                if !currentItem.audioURL.isEmpty {
                    if currentItem.guid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        currentItem.guid = currentItem.audioURL
                    }
                    episodes.append(currentItem)
                }
                inItem = false
            default:
                break
            }
            return
        }

        switch name {
        case "title":
            channelTitle = text
        case "description", "subtitle":
            if channelDescription.isEmpty {
                channelDescription = text
            }
        case "link":
            if channelLink.isEmpty {
                channelLink = text
            }
        case "url" where inChannelImage:
            channelImageURL = text
        case "image":
            inChannelImage = false
        default:
            break
        }
    }
}

func parseFeedDate(_ value: String) -> Int64 {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        return 0
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    let formats = [
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "EEE, d MMM yyyy HH:mm:ss zzz",
        "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
        "yyyy-MM-dd'T'HH:mm:ss'Z'",
        "yyyy-MM-dd"
    ]
    for format in formats {
        formatter.dateFormat = format
        if let date = formatter.date(from: trimmed) {
            return Int64(date.timeIntervalSince1970)
        }
    }
    return 0
}

func parseDuration(_ value: String) -> Int64? {
    let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
    if parts.isEmpty {
        return nil
    }
    if parts.count == 1 {
        return Int64(parts[0])
    }
    var total: Int64 = 0
    for part in parts {
        guard let value = Int64(part) else {
            return nil
        }
        total = total * 60 + value
    }
    return total
}

func stripHTML(_ html: String) -> String {
    html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
