use quick_xml::events::Event;
use quick_xml::Reader;

/// Pull every outline xmlUrl out of an OPML document, in order, deduplicated.
pub fn parse_opml(xml: &str) -> Vec<String> {
    let mut reader = Reader::from_str(xml);
    let mut urls = Vec::new();
    let mut seen = std::collections::HashSet::new();
    loop {
        match reader.read_event() {
            Ok(Event::Start(e)) | Ok(Event::Empty(e)) => {
                if e.name().as_ref() != b"outline" {
                    continue;
                }
                for attr in e.attributes().flatten() {
                    if attr.key.as_ref() == b"xmlUrl" {
                        if let Ok(v) = attr.unescape_value() {
                            let url = v.trim().to_string();
                            if !url.is_empty() && seen.insert(url.clone()) {
                                urls.push(url);
                            }
                        }
                    }
                }
            }
            Ok(Event::Eof) | Err(_) => break,
            _ => {}
        }
    }
    urls
}

pub fn render_opml(items: &[(String, String)]) -> String {
    let esc = |s: &str| quick_xml::escape::escape(s).into_owned();
    let mut out = String::from(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<opml version=\"2.0\">\n  <head><title>Pods subscriptions</title></head>\n  <body>\n",
    );
    for (title, url) in items {
        out.push_str(&format!(
            "    <outline type=\"rss\" text=\"{0}\" title=\"{0}\" xmlUrl=\"{1}\"/>\n",
            esc(title),
            esc(url)
        ));
    }
    out.push_str("  </body>\n</opml>\n");
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_nested_and_flat_outlines() {
        let xml = r#"<?xml version="1.0"?><opml version="2.0"><body>
          <outline text="group">
            <outline type="rss" text="A &amp; B" xmlUrl="https://a.example/feed.xml"/>
          </outline>
          <outline type="rss" text="C" xmlUrl="https://c.example/rss"/>
          <outline type="rss" text="dup" xmlUrl="https://a.example/feed.xml"/>
          <outline text="no url"/>
        </body></opml>"#;
        assert_eq!(
            parse_opml(xml),
            vec!["https://a.example/feed.xml", "https://c.example/rss"]
        );
    }

    #[test]
    fn parse_garbage_yields_empty() {
        assert!(parse_opml("not xml at all").is_empty());
    }

    #[test]
    fn renders_escaped_roundtrippable_opml() {
        let items = vec![("Tom & Jerry \"show\"".to_string(), "https://x.example/f?a=1&b=2".to_string())];
        let xml = render_opml(&items);
        assert!(xml.contains("Tom &amp; Jerry"));
        assert_eq!(parse_opml(&xml), vec!["https://x.example/f?a=1&b=2"]);
    }
}
