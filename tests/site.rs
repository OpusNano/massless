//! End-to-end checks of every generated page against the real binary.

mod common;

use common::{Resp, Server};

/// Slugs of all posts, from the `posts/` file names
/// (`YYYY-MM-DD-slug.md` or `YYYY-MM-DD-HH-MM-SS-slug.md`).
fn slugs() -> Vec<String> {
    let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/posts");
    let mut out: Vec<String> = std::fs::read_dir(dir)
        .unwrap()
        .filter_map(|e| {
            let name = e.unwrap().file_name().into_string().ok()?;
            let stem = name.strip_suffix(".md")?;
            let parts: Vec<&str> = stem.split('-').collect();
            let time = parts.len() > 6
                && parts[3..6]
                    .iter()
                    .all(|p| p.len() == 2 && p.bytes().all(|b| b.is_ascii_digit()));
            Some(parts[if time { 6 } else { 3 }..].join("-"))
        })
        .collect();
    out.sort();
    assert!(!out.is_empty(), "no posts in {dir}");
    out
}

/// Checks the headers every cacheable 200 must have.
fn assert_page(r: &Resp, content_type: &str) {
    assert_eq!(r.status, 200, "{r:?}");
    assert_eq!(r.header("content-type"), Some(content_type));
    assert_eq!(r.header("vary"), Some("Accept-Encoding"));
    assert_eq!(r.header("cache-control"), Some("no-cache"));
    assert_eq!(r.header("x-content-type-options"), Some("nosniff"));
    assert_eq!(r.header("referrer-policy"), Some("no-referrer"));
    let csp = r.header("content-security-policy").unwrap();
    assert!(csp.contains("default-src 'none'") && !csp.contains("script-src"));
    let etag = r.header("etag").unwrap();
    assert!(etag.starts_with('"') && etag.ends_with('"'), "{etag}");
    let len: usize = r.header("content-length").unwrap().parse().unwrap();
    assert_eq!(len, r.body.len());
}

#[test]
fn every_page_is_served() {
    let srv = Server::start();
    let index = srv.get("/", &[]);
    assert_page(&index, "text/html; charset=utf-8");
    assert_eq!(index.header("content-encoding"), None);
    let html = index.text();
    assert!(html.starts_with("<!doctype html>") || html.starts_with("<!DOCTYPE html>"));
    assert!(!html.contains("<script"));
    for slug in slugs() {
        let path = format!("/posts/{slug}");
        assert!(
            html.contains(&format!("href=\"{path}\"")),
            "index lacks {path}"
        );
        let post = srv.get(&path, &[]);
        assert_page(&post, "text/html; charset=utf-8");
        assert!(post.text().contains("<h1>"), "{path}");
        // Query strings are ignored.
        assert_eq!(srv.get(&format!("{path}?x=1"), &[]).body, post.body);
    }

    let feed = srv.get("/feed.xml", &[]);
    assert_page(&feed, "application/atom+xml; charset=utf-8");
    let xml = feed.text();
    assert!(xml.contains("<feed xmlns=\"http://www.w3.org/2005/Atom\""));
    assert_eq!(xml.matches("<entry>").count(), slugs().len());
}

#[test]
fn not_found_redirect_and_methods() {
    let srv = Server::start();
    let nf = srv.get("/no/such/page", &[]);
    assert_eq!(nf.status, 404);
    assert_eq!(nf.header("content-type"), Some("text/html; charset=utf-8"));
    assert!(nf.text().contains("Not found"));
    assert_eq!(nf.header("etag"), None);

    let r = srv.get("/posts", &[]);
    assert_eq!(r.status, 301);
    assert_eq!(r.header("location"), Some("/"));

    let r = srv.request("DELETE", "/", &[]);
    assert_eq!(r.status, 405);
    assert_eq!(r.header("allow"), Some("GET, HEAD"));
}

#[test]
fn encodings_etags_and_head() {
    let srv = Server::start();
    for path in ["/", "/feed.xml"] {
        let plain = srv.get(path, &[]);
        let gz = srv.get(path, &["Accept-Encoding: gzip"]);
        let br = srv.get(path, &["Accept-Encoding: gzip, deflate, br"]);
        assert_page(&gz, plain.header("content-type").unwrap());
        assert_page(&br, plain.header("content-type").unwrap());
        assert_eq!(gz.header("content-encoding"), Some("gzip"));
        assert_eq!(br.header("content-encoding"), Some("br"));
        assert_eq!(&gz.body[..2], &[0x1f, 0x8b], "gzip magic");
        assert!(br.body.len() < gz.body.len() && gz.body.len() < plain.body.len());
        let none = srv.get(path, &["Accept-Encoding: br;q=0, gzip;q=0"]);
        assert_eq!(none.body, plain.body);

        // Each variant has its own ETag; a matching one gives an empty 304.
        let etags = [&plain, &gz, &br].map(|r| r.header("etag").unwrap().to_string());
        assert!(etags[0] != etags[1] && etags[1] != etags[2] && etags[0] != etags[2]);
        let inm = format!("If-None-Match: {}", etags[2]);
        let r = srv.get(path, &["Accept-Encoding: br", &inm]);
        assert_eq!(r.status, 304);
        assert!(r.body.is_empty());
        assert_eq!(r.header("etag"), Some(etags[2].as_str()));
        // ...but not for another variant.
        assert_eq!(srv.get(path, &[&inm]).status, 200);

        let head = srv.request("HEAD", path, &["Accept-Encoding: br"]);
        assert_eq!(head.status, 200);
        assert!(head.body.is_empty());
        assert_eq!(
            head.header("content-length"),
            Some(br.body.len().to_string().as_str())
        );
    }
}

#[test]
fn keep_alive_and_bad_requests() {
    let srv = Server::start();
    // Two pipelined requests on one connection: HEAD sends no body, so the
    // second response follows the first header block directly.
    let (out, _) = srv.raw(
        b"HEAD / HTTP/1.1\r\nHost: t\r\n\r\nGET /feed.xml HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n",
    );
    let second = out.split("\r\n\r\n").nth(1).unwrap_or("");
    assert!(second.starts_with("HTTP/1.1 200 OK"), "{out:?}");

    // Garbage and a truncated request are answered or closed, not hung.
    assert!(
        srv.status(b"\x16\x03\x01garbage\r\n\r\n")
            .starts_with("HTTP/1.1 400 ")
    );
    let (resp, took) = srv.raw(b"GET / HTTP/1.1\r\nHo");
    assert!(resp.is_empty(), "{resp:?}");
    assert!(took < std::time::Duration::from_secs(3), "{took:?}");
    srv.assert_alive();
}
