//! Site rendering: posts + templates -> finished pages.
//!
//! Shared by `build.rs` (via `#[path]`) and, later, dev mode. Pure except for
//! `load`, which reads the input directories.

use pulldown_cmark::{Event, HeadingLevel, Options, Parser, Tag, TagEnd, html};
use std::{fs, path::Path};

pub const SITE_TITLE: &str = "massless";
pub const HTML: &str = "text/html; charset=utf-8";
pub const ATOM: &str = "application/atom+xml; charset=utf-8";

/// Raw inputs: post files and templates.
pub struct Input {
    /// (file name, contents) of every `*.md` in `posts/`.
    pub posts: Vec<(String, String)>,
    pub layout: String,
    pub style: String,
}

/// One finished response body at a path.
pub struct Output {
    pub path: String,
    pub content_type: &'static str,
    pub body: Vec<u8>,
}

/// The whole rendered site.
pub struct Site {
    /// Sorted by path, unique.
    pub pages: Vec<Output>,
    pub not_found: Vec<u8>,
}

#[derive(Debug)]
struct Post {
    slug: String,
    title: String,
    /// YYYY-MM-DD
    date: String,
    /// HH:MM:SS (from the file name, else midnight)
    time: String,
    summary: Option<String>,
    html: String,
}

/// Read `posts/*.md` and the templates from disk.
pub fn load(posts_dir: &Path, templates_dir: &Path) -> Result<Input, String> {
    let read = |p: &Path| fs::read_to_string(p).map_err(|e| format!("{}: {e}", p.display()));
    let mut posts = Vec::new();
    let dir = fs::read_dir(posts_dir).map_err(|e| format!("{}: {e}", posts_dir.display()))?;
    for entry in dir {
        let path = entry.map_err(|e| e.to_string())?.path();
        let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        if name.starts_with('.') || !name.ends_with(".md") {
            continue;
        }
        posts.push((name.to_owned(), read(&path)?));
    }
    Ok(Input {
        posts,
        layout: read(&templates_dir.join("layout.html"))?,
        style: read(&templates_dir.join("style.css"))?,
    })
}

/// Render the whole site. `site_url` (no trailing slash, may be empty)
/// prefixes links in the feed.
pub fn render(input: &Input, site_url: &str) -> Result<Site, String> {
    let mut posts = input
        .posts
        .iter()
        .map(|(name, text)| parse_post(name, text).map_err(|e| format!("posts/{name}: {e}")))
        .collect::<Result<Vec<_>, _>>()?;
    // Newest first.
    posts.sort_by(|a, b| (&b.date, &b.time, &b.slug).cmp(&(&a.date, &a.time, &a.slug)));
    let mut slugs: Vec<&str> = posts.iter().map(|p| p.slug.as_str()).collect();
    slugs.sort_unstable();
    if let Some(w) = slugs.windows(2).find(|w| w[0] == w[1]) {
        return Err(format!("duplicate post slug {:?}", w[0]));
    }

    let page = |title: &str, description: &str, content: &str| {
        fill(
            &input.layout,
            &[
                ("title", &escape(title)),
                ("description", &escape(description)),
                ("site", &escape(SITE_TITLE)),
                ("style", &input.style),
                ("content", content),
            ],
        )
        .map(String::into_bytes)
        .map_err(|e| format!("templates/layout.html: {e}"))
    };

    let mut pages = vec![
        Output {
            path: "/".into(),
            content_type: HTML,
            body: page(SITE_TITLE, SITE_TITLE, &index_html(&posts))?,
        },
        Output {
            path: "/feed.xml".into(),
            content_type: ATOM,
            body: feed_xml(&posts, site_url).into_bytes(),
        },
    ];
    for p in &posts {
        let content = format!(
            "<article><h1>{}</h1><p><time datetime=\"{d}\">{d}</time></p>\n{}</article>\n",
            escape(&p.title),
            p.html,
            d = p.date,
        );
        let title = format!("{} — {SITE_TITLE}", p.title);
        let desc = p.summary.as_deref().unwrap_or(&p.title);
        pages.push(Output {
            path: format!("/posts/{}", p.slug),
            content_type: HTML,
            body: page(&title, desc, &content)?,
        });
    }
    pages.sort_by(|a, b| a.path.cmp(&b.path));

    let not_found = page(
        &format!("Not found — {SITE_TITLE}"),
        "Page not found",
        "<h1>Not found</h1>\n<p>No such page. <a href=\"/\">Back to the index</a>.</p>\n",
    )?;
    Ok(Site { pages, not_found })
}

fn index_html(posts: &[Post]) -> String {
    if posts.is_empty() {
        return "<p>No posts yet.</p>\n".into();
    }
    let mut s = String::from("<ul class=\"posts\">\n");
    for p in posts {
        s += &format!(
            "<li><time datetime=\"{d}\">{d}</time> <a href=\"/posts/{}\">{}</a>",
            p.slug,
            escape(&p.title),
            d = p.date,
        );
        if let Some(sum) = &p.summary {
            s += &format!("<p>{}</p>", escape(sum));
        }
        s += "</li>\n";
    }
    s + "</ul>\n"
}

fn feed_xml(posts: &[Post], site: &str) -> String {
    let updated = posts.first().map_or("1970-01-01T00:00:00Z".into(), |p| {
        format!("{}T{}Z", p.date, p.time)
    });
    let mut s = format!(
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n\
         <feed xmlns=\"http://www.w3.org/2005/Atom\">\n\
         <title>{t}</title>\n<id>tag:massless,2026:feed</id>\n\
         <link href=\"{site}/\"/>\n<link rel=\"self\" href=\"{site}/feed.xml\"/>\n\
         <updated>{updated}</updated>\n<author><name>{t}</name></author>\n",
        t = escape(SITE_TITLE),
        site = escape(site),
    );
    for p in posts {
        s += &format!(
            "<entry>\n<title>{}</title>\n<id>tag:massless,{}:{slug}</id>\n\
             <link href=\"{}/posts/{slug}\"/>\n<updated>{}T{}Z</updated>\n",
            escape(&p.title),
            p.date,
            escape(site),
            p.date,
            p.time,
            slug = p.slug,
        );
        if let Some(sum) = &p.summary {
            s += &format!("<summary>{}</summary>\n", escape(sum));
        }
        s += &format!(
            "<content type=\"html\">{}</content>\n</entry>\n",
            escape(&p.html)
        );
    }
    s + "</feed>\n"
}

/// Parse `YYYY-MM-DD[-HH-MM-SS]-slug.md` plus its frontmatter and body.
fn parse_post(name: &str, text: &str) -> Result<Post, String> {
    let (file_date, time, slug) = parse_name(name)?;
    let (front, body) = split_frontmatter(text)?;

    let (mut title, mut date, mut summary) = (None, None, None);
    for (i, line) in front.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once(':') else {
            return Err(format!("frontmatter line {}: expected `key: value`", i + 2));
        };
        let value = unquote(value.trim()).to_owned();
        match key.trim() {
            "title" => title = Some(value),
            "date" => date = Some(value),
            "summary" => summary = Some(value).filter(|s| !s.is_empty()),
            _ => {} // unknown keys are ignored
        }
    }
    let title = title
        .filter(|t| !t.is_empty())
        .ok_or("missing `title` in frontmatter")?;
    let date = match date {
        Some(d) if valid_date(&d) => d,
        Some(d) => return Err(format!("bad `date` {d:?}, expected YYYY-MM-DD")),
        None => file_date,
    };
    Ok(Post {
        slug,
        title,
        date,
        time,
        summary,
        html: markdown(body),
    })
}

/// File name -> (date, time, slug).
fn parse_name(name: &str) -> Result<(String, String, String), String> {
    let stem = name
        .strip_suffix(".md")
        .ok_or("file name must end in .md")?;
    let bad = || "file name must be YYYY-MM-DD[-HH-MM-SS]-slug.md".to_string();
    let (date, rest) = (stem.get(..10).ok_or_else(bad)?, &stem[10..]);
    let rest = rest.strip_prefix('-').ok_or_else(bad)?;
    if !valid_date(date) {
        return Err(format!("bad date {date:?} in file name"));
    }
    let (time, slug) = match rest.get(..9) {
        Some(t) if t.ends_with('-') && valid_time(&t[..8]) => {
            (t[..8].replace('-', ":"), &rest[9..])
        }
        _ => ("00:00:00".to_string(), rest),
    };
    let ok_slug = !slug.is_empty()
        && slug.split('-').all(|w| {
            !w.is_empty()
                && w.bytes()
                    .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
        });
    if !ok_slug {
        return Err(format!(
            "bad slug {slug:?}: use lowercase a-z, 0-9 and single dashes"
        ));
    }
    Ok((date.to_string(), time, slug.to_string()))
}

/// Split `---\n...\n---\n` from the body.
fn split_frontmatter(text: &str) -> Result<(&str, &str), String> {
    let missing = || "missing frontmatter (`---` block with a title)".to_string();
    let text = text.strip_prefix('\u{feff}').unwrap_or(text);
    let mut lines = text.split_inclusive('\n');
    if lines.next().map(str::trim_end) != Some("---") {
        return Err(missing());
    }
    let start = text.find('\n').ok_or_else(missing)? + 1;
    let mut pos = start;
    for line in lines {
        if line.trim_end() == "---" {
            return Ok((&text[start..pos], &text[pos + line.len()..]));
        }
        pos += line.len();
    }
    Err("frontmatter is not closed with `---`".into())
}

fn unquote(s: &str) -> &str {
    for q in ['"', '\''] {
        if let Some(inner) = s.strip_prefix(q).and_then(|s| s.strip_suffix(q)) {
            return inner;
        }
    }
    s
}

fn digits(s: &str, at: &[usize]) -> Option<Vec<u32>> {
    let b = s.as_bytes();
    let mut prev = 0;
    let mut out = Vec::new();
    for &end in at.iter().chain([&s.len()]) {
        let part = s.get(prev..end)?;
        if part.is_empty() || !part.bytes().all(|c| c.is_ascii_digit()) {
            return None;
        }
        out.push(part.parse().ok()?);
        if end < s.len() && b[end] != b'-' {
            return None;
        }
        prev = end + 1;
    }
    Some(out)
}

fn valid_date(s: &str) -> bool {
    if s.len() != 10 {
        return false;
    }
    let Some(v) = digits(s, &[4, 7]) else {
        return false;
    };
    let (y, m, d) = (v[0], v[1], v[2]);
    let leap = y % 4 == 0 && (y % 100 != 0 || y % 400 == 0);
    let days = match m {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if leap => 29,
        2 => 28,
        _ => return false,
    };
    (1..=days).contains(&d)
}

fn valid_time(s: &str) -> bool {
    s.len() == 8 && digits(s, &[2, 5]).is_some_and(|v| v[0] < 24 && v[1] < 60 && v[2] < 60)
}

/// Markdown -> HTML. Headings are shifted down one level, since the page
/// title is the only `<h1>`.
fn markdown(md: &str) -> String {
    let opts = Options::ENABLE_TABLES
        | Options::ENABLE_FOOTNOTES
        | Options::ENABLE_STRIKETHROUGH
        | Options::ENABLE_TASKLISTS
        | Options::ENABLE_SMART_PUNCTUATION;
    let down = |l: HeadingLevel| HeadingLevel::try_from(l as usize + 1).unwrap_or(l);
    let events = Parser::new_ext(md, opts).map(|e| match e {
        Event::Start(Tag::Heading {
            level,
            id,
            classes,
            attrs,
        }) => Event::Start(Tag::Heading {
            level: down(level),
            id,
            classes,
            attrs,
        }),
        Event::End(TagEnd::Heading(level)) => Event::End(TagEnd::Heading(down(level))),
        e => e,
    });
    let mut out = String::with_capacity(md.len() * 3 / 2);
    html::push_html(&mut out, events);
    out
}

/// Escape text for HTML and XML content and attributes.
fn escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            c => out.push(c),
        }
    }
    out
}

/// Replace `{{name}}` placeholders in one pass; unknown names are errors.
fn fill(template: &str, vars: &[(&str, &str)]) -> Result<String, String> {
    let mut out = String::with_capacity(template.len() * 2);
    let mut rest = template;
    while let Some(i) = rest.find("{{") {
        out.push_str(&rest[..i]);
        let after = &rest[i + 2..];
        let end = after.find("}}").ok_or("unclosed `{{`")?;
        let name = after[..end].trim();
        let value = vars
            .iter()
            .find(|(k, _)| *k == name)
            .ok_or_else(|| format!("unknown placeholder {{{{{name}}}}}"))?
            .1;
        out.push_str(value);
        rest = &after[end + 2..];
    }
    out.push_str(rest);
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    const LAYOUT: &str = "<title>{{title}}</title><meta content=\"{{description}}\">{{content}}";

    fn site(posts: &[(&str, &str)]) -> Result<Site, String> {
        let input = Input {
            posts: posts
                .iter()
                .map(|(n, t)| (n.to_string(), t.to_string()))
                .collect(),
            layout: LAYOUT.into(),
            style: String::new(),
        };
        render(&input, "")
    }

    fn body<'a>(s: &'a Site, path: &str) -> &'a str {
        let page = s.pages.iter().find(|p| p.path == path).unwrap();
        std::str::from_utf8(&page.body).unwrap()
    }

    #[test]
    fn file_names() {
        assert_eq!(
            parse_name("2026-09-12-salyut-7-rescue.md").unwrap(),
            (
                "2026-09-12".into(),
                "00:00:00".into(),
                "salyut-7-rescue".into()
            )
        );
        assert_eq!(
            parse_name("2024-02-29-13-05-09-x.md").unwrap(),
            ("2024-02-29".into(), "13:05:09".into(), "x".into())
        );
        for bad in [
            "2026-09-12.md",
            "2026-09-12-.md",
            "2026-13-01-x.md",
            "2025-02-29-x.md",
            "26-09-12-x.md",
            "2026-09-12-Hello.md",
            "2026-09-12-a--b.md",
            "2026-09-12-a-.md",
            "2026-09-12-x.txt",
            "2026-09-12_x.md",
            "2026-09-12-ü.md",
        ] {
            assert!(parse_name(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn date_falls_back_to_file_name() {
        let p = parse_post("2026-09-12-a.md", "---\ntitle: A\n---\nhi\n").unwrap();
        assert_eq!((p.date.as_str(), p.title.as_str()), ("2026-09-12", "A"));
        assert_eq!(p.summary, None);
        let p = parse_post(
            "2026-09-12-a.md",
            "---\r\ntitle: \"A: b\"\r\ndate: 2020-01-02\r\nsummary: 's'\r\n---\r\nhi",
        )
        .unwrap();
        assert_eq!(
            (p.date.as_str(), p.title.as_str(), p.summary.as_deref()),
            ("2020-01-02", "A: b", Some("s"))
        );
    }

    #[test]
    fn malformed_posts_fail() {
        for text in [
            "no frontmatter\n",
            "---\ntitle: A\n",
            "---\ndate: 2026-01-01\n---\n",
            "---\ntitle:\n---\n",
            "---\ntitle: A\ndate: 2026-1-1\n---\n",
            "---\ntitle A\n---\n",
        ] {
            assert!(parse_post("2026-09-12-a.md", text).is_err(), "{text:?}");
        }
    }

    #[test]
    fn markdown_features() {
        let h = markdown("# H\n\n~~s~~ \"q\"\n\n- [x] t\n\n|a|\n|-|\n|b|\n\nx[^1]\n\n[^1]: f\n");
        for want in [
            "<h2>H</h2>",
            "<del>s</del>",
            "“q”",
            "checkbox",
            "<table>",
            "footnote",
        ] {
            assert!(h.contains(want), "{want} in {h}");
        }
    }

    #[test]
    fn renders_site() {
        let s = site(&[
            ("2026-01-01-old.md", "---\ntitle: Old <1>\n---\nold\n"),
            (
                "2026-02-01-new.md",
                "---\ntitle: New\nsummary: Fresh & new\n---\n# Hi\n",
            ),
        ])
        .unwrap();
        let paths: Vec<_> = s.pages.iter().map(|p| p.path.as_str()).collect();
        assert_eq!(paths, ["/", "/feed.xml", "/posts/new", "/posts/old"]);
        let index = body(&s, "/");
        assert!(index.find("/posts/new").unwrap() < index.find("/posts/old").unwrap());
        assert!(index.contains("Old &lt;1&gt;") && index.contains("Fresh &amp; new"));
        let post = body(&s, "/posts/new");
        assert!(post.contains("<h1>New</h1>") && post.contains("<h2>Hi</h2>"));
        assert!(post.contains("<title>New — massless</title>"));
        let feed = body(&s, "/feed.xml");
        assert!(feed.contains("<updated>2026-02-01T00:00:00Z</updated>"));
        assert!(feed.contains("&lt;h2&gt;Hi&lt;/h2&gt;"));
        assert!(
            std::str::from_utf8(&s.not_found)
                .unwrap()
                .contains("Not found")
        );
    }

    #[test]
    fn real_content_renders() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR"));
        let input = load(&root.join("posts"), &root.join("templates")).unwrap();
        assert!(!input.posts.is_empty());
        let s = render(&input, "https://example.org").unwrap();
        assert_eq!(s.pages.len(), input.posts.len() + 2);
        for p in &s.pages {
            let want = if p.path == "/feed.xml" { ATOM } else { HTML };
            assert_eq!(p.content_type, want, "{}", p.path);
        }
        assert!(body(&s, "/feed.xml").contains("href=\"https://example.org/posts/"));
    }

    #[test]
    fn empty_site_and_duplicates() {
        assert!(body(&site(&[]).unwrap(), "/").contains("No posts yet"));
        let dup = site(&[
            ("2026-01-01-a.md", "---\ntitle: A\n---\n"),
            ("2026-01-02-a.md", "---\ntitle: A\n---\n"),
        ]);
        assert!(dup.err().unwrap().contains("duplicate"));
    }

    #[test]
    fn templates() {
        assert_eq!(
            fill("a{{ x }}b{{y}}", &[("x", "{{y}}"), ("y", "2")]).unwrap(),
            "a{{y}}b2"
        );
        assert!(fill("{{nope}}", &[]).is_err());
        assert!(fill("{{x", &[("x", "")]).is_err());
    }
}
