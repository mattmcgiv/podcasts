import Foundation

final class OPMLParserDelegate: NSObject, XMLParserDelegate {
    private(set) var urls: [String] = []
    private var seen = Set<String>()

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName.lowercased() == "outline" else {
            return
        }
        guard let raw = attributeDict["xmlUrl"] ?? attributeDict["xmlurl"] else {
            return
        }
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.isEmpty && seen.insert(url).inserted {
            urls.append(url)
        }
    }
}

enum PodsOPML {
    static func parse(_ xml: String) -> [String] {
        guard let data = xml.data(using: .utf8) else {
            return []
        }
        let delegate = OPMLParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.urls
    }

    static func render(_ shows: [(title: String, feedURL: String)]) -> String {
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head><title>Pods subscriptions</title></head>
          <body>

        """
        for show in shows {
            out += "    <outline type=\"rss\" text=\"\(escapeAttribute(show.title))\" title=\"\(escapeAttribute(show.title))\" xmlUrl=\"\(escapeAttribute(show.feedURL))\"/>\n"
        }
        out += "  </body>\n</opml>\n"
        return out
    }

    private static func escapeAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

