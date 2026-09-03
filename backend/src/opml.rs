pub fn parse(xml: &str) -> Vec<String> {
    let mut urls = Vec::new();
    let mut seen = std::collections::HashSet::new();
    let lower = xml;
    let mut rest = lower;
    while let Some(idx) = rest.to_lowercase().find("<outline") {
        rest = &rest[idx + 8..];
        let end = rest.find('>').unwrap_or(rest.len());
        let attrs = &rest[..end];
        let url = attr(attrs, "xmlUrl").or_else(|| attr(attrs, "xmlurl"));
        if let Some(url) = url {
            let url = url.trim().to_string();
            if !url.is_empty() && seen.insert(url.clone()) {
                urls.push(url);
            }
        }
        rest = &rest[end.min(rest.len())..];
    }
    urls
}

fn attr(src: &str, name: &str) -> Option<String> {
    let needle = format!("{name}=");
    let lower = src.to_lowercase();
    let pos = lower.find(&needle.to_lowercase())?;
    let after = src[pos + needle.len()..].trim_start();
    if after.starts_with('"') || after.starts_with('\'') {
        let q = after.chars().next()?;
        let rest = &after[1..];
        let end = rest.find(q)?;
        Some(unescape(&rest[..end]))
    } else {
        None
    }
}

fn unescape(value: &str) -> String {
    value
        .replace("&quot;", "\"")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&amp;", "&")
}

pub fn render(shows: &[(String, String)]) -> String {
    let mut out = String::from(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<opml version=\"2.0\">\n  <head><title>Pods subscriptions</title></head>\n  <body>\n",
    );
    for (title, feed_url) in shows {
        out.push_str(&format!(
            "    <outline type=\"rss\" text=\"{}\" title=\"{}\" xmlUrl=\"{}\"/>\n",
            escape(title),
            escape(title),
            escape(feed_url)
        ));
    }
    out.push_str("  </body>\n</opml>\n");
    out
}

fn escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('"', "&quot;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}
