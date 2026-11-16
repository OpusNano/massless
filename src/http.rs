//! HTTP semantics on top of routing: content negotiation, ETags and 304,
//! caching and security headers. Pure logic, no I/O, no allocations.

use crate::routes::{Method, Page, Reply, Variant, route};

/// Headers sent with every response.
const COMMON: [(&str, &str); 4] = [
    ("Server", "massless"),
    ("X-Content-Type-Options", "nosniff"),
    ("Referrer-Policy", "no-referrer"),
    (
        "Content-Security-Policy",
        "default-src 'none'; style-src 'unsafe-inline'; img-src * data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
    ),
];
const MAX_HEADERS: usize = COMMON.len() + 5;

/// A fully decided response. Everything is static: building one allocates
/// nothing.
#[derive(Debug)]
pub struct Out {
    pub status: u16,
    /// The selected body. For HEAD and 304 tiny_http sends only its length
    /// as `Content-Length` (which is what a 200 would have sent).
    pub body: &'static [u8],
    headers: [(&'static str, &'static str); MAX_HEADERS],
    len: usize,
}

impl Out {
    fn new(status: u16, body: &'static [u8]) -> Self {
        let mut out = Out {
            status,
            body,
            headers: [("", ""); MAX_HEADERS],
            len: 0,
        };
        for (name, value) in COMMON {
            out.push(name, value);
        }
        out
    }

    fn push(&mut self, name: &'static str, value: &'static str) {
        // The header count is fixed per branch and covered by tests;
        // never panic on overflow anyway.
        if let Some(slot) = self.headers.get_mut(self.len) {
            *slot = (name, value);
            self.len += 1;
        }
    }

    pub fn headers(&self) -> &[(&'static str, &'static str)] {
        &self.headers[..self.len]
    }

    #[cfg(test)]
    pub fn header(&self, name: &str) -> Option<&'static str> {
        self.headers()
            .iter()
            .find(|(n, _)| n.eq_ignore_ascii_case(name))
            .map(|(_, v)| *v)
    }
}

/// Builds the response for a request. `accept_encoding` and `if_none_match`
/// are the values of all such request headers.
pub fn respond<'a>(
    method: Method,
    url: &str,
    accept_encoding: impl Iterator<Item = &'a str>,
    if_none_match: impl Iterator<Item = &'a str>,
) -> Out {
    match route(method, url) {
        Reply::Ok(page) => {
            let (v, coding) = select(page, accept_encoding);
            let fresh = etag_matches(if_none_match, v.etag);
            let mut out = Out::new(if fresh { 304 } else { 200 }, v.body);
            if !fresh {
                // A 304 carries no representation metadata (RFC 9110 15.4.5).
                out.push("Content-Type", page.content_type);
                if let Some(c) = coding {
                    out.push("Content-Encoding", c);
                }
            }
            out.push("Vary", "Accept-Encoding");
            out.push("ETag", v.etag);
            out.push("Cache-Control", "no-cache");
            out
        }
        Reply::NotFound(page) => {
            let (v, coding) = select(page, accept_encoding);
            let mut out = Out::new(404, v.body);
            out.push("Content-Type", page.content_type);
            if let Some(c) = coding {
                out.push("Content-Encoding", c);
            }
            out.push("Vary", "Accept-Encoding");
            out.push("Cache-Control", "no-cache");
            out
        }
        Reply::Redirect(to) => {
            let mut out = Out::new(301, b"");
            out.push("Location", to);
            out
        }
        Reply::MethodNotAllowed(page) => {
            let mut out = Out::new(405, page.identity.body);
            out.push("Content-Type", page.content_type);
            out.push("Allow", "GET, HEAD");
            out
        }
    }
}

/// Picks the best variant the client accepts: br > gzip > identity.
/// Returns the variant and its `Content-Encoding` value, if any.
fn select<'a>(
    page: &'static Page,
    accept_encoding: impl Iterator<Item = &'a str>,
) -> (&'static Variant, Option<&'static str>) {
    let acc = accepted(accept_encoding);
    match (&page.br, &page.gzip) {
        (Some(v), _) if acc.br => (v, Some("br")),
        (_, Some(v)) if acc.gzip => (v, Some("gzip")),
        _ => (&page.identity, None),
    }
}

/// Which content codings the client accepts.
#[derive(Debug, PartialEq, Eq)]
struct Accepted {
    br: bool,
    gzip: bool,
}

/// Parses `Accept-Encoding` values. A coding is accepted if listed (or
/// covered by `*`) with a non-zero q. No header means identity only.
/// Identity itself is always available: we never answer 406.
fn accepted<'a>(values: impl Iterator<Item = &'a str>) -> Accepted {
    let (mut br, mut gzip, mut star) = (None, None, None);
    for item in values.flat_map(|v| v.split(',')) {
        let mut parts = item.split(';');
        let name = parts.next().unwrap_or("").trim();
        let mut ok = true;
        for param in parts {
            if let Some((k, v)) = param.split_once('=')
                && k.trim().eq_ignore_ascii_case("q")
            {
                ok = !q_is_zero(v.trim());
            }
        }
        if name.eq_ignore_ascii_case("br") {
            br = Some(ok);
        } else if name.eq_ignore_ascii_case("gzip") || name.eq_ignore_ascii_case("x-gzip") {
            gzip = Some(ok);
        } else if name == "*" {
            star = Some(ok);
        }
    }
    Accepted {
        br: br.or(star).unwrap_or(false),
        gzip: gzip.or(star).unwrap_or(false),
    }
}

/// `0`, `0.`, `0.0`, `0.000` (RFC 9110 qvalue zero).
fn q_is_zero(q: &str) -> bool {
    q.strip_prefix('0').is_some_and(|rest| {
        rest.is_empty()
            || rest
                .strip_prefix('.')
                .is_some_and(|d| d.bytes().all(|b| b == b'0'))
    })
}

/// `If-None-Match` uses weak comparison: `W/` is ignored; `*` matches.
fn etag_matches<'a>(values: impl Iterator<Item = &'a str>, etag: &str) -> bool {
    values.flat_map(|v| v.split(',')).any(|t| {
        let t = t.trim();
        t == "*" || t.strip_prefix("W/").unwrap_or(t) == etag
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::routes::{NOT_ALLOWED, NOT_FOUND, PAGES};

    fn get(url: &str, ae: &[&str], inm: &[&str]) -> Out {
        respond(Method::Get, url, ae.iter().copied(), inm.iter().copied())
    }

    fn acc(v: &str) -> Accepted {
        accepted(std::iter::once(v))
    }

    fn index() -> &'static Page {
        &PAGES.iter().find(|(p, _)| *p == "/").unwrap().1
    }

    #[test]
    fn accept_encoding_parsing() {
        let both = Accepted {
            br: true,
            gzip: true,
        };
        let none = Accepted {
            br: false,
            gzip: false,
        };
        let gz = Accepted {
            br: false,
            gzip: true,
        };
        let br = Accepted {
            br: true,
            gzip: false,
        };
        assert_eq!(accepted(std::iter::empty()), none);
        assert_eq!(acc(""), none);
        assert_eq!(acc("gzip, deflate, br, zstd"), both);
        assert_eq!(acc("GZIP;q=0.5,BR;q=1.0"), both);
        assert_eq!(acc("br;q=0, gzip"), gz);
        assert_eq!(acc("br ; q = 0.000 , gzip;q=0.001"), gz);
        assert_eq!(acc("x-gzip"), gz);
        assert_eq!(acc("gzip;q=0., br"), br);
        assert_eq!(acc("*"), both);
        assert_eq!(acc("*;q=0"), none);
        assert_eq!(acc("*;q=0, br"), br);
        assert_eq!(acc("*, gzip;q=0"), br);
        assert_eq!(acc("identity"), none);
        assert_eq!(acc("deflate, compress"), none);
        // Split over several header lines.
        assert_eq!(accepted(["gzip", "br"].into_iter()), both);
        // Garbage must not panic.
        for g in [";;;", ",,,", "q=0", ";q=", "br;q", "br;=0", "\u{1F600};q=0"] {
            let _ = acc(g);
        }
    }

    #[test]
    fn qvalue_zero() {
        for z in ["0", "0.", "0.0", "0.000"] {
            assert!(q_is_zero(z), "{z}");
        }
        for nz in ["1", "0.5", "0.001", "1.0", "", "00", "x", "0.0x"] {
            assert!(!q_is_zero(nz), "{nz}");
        }
    }

    #[test]
    fn encoding_negotiation() {
        let page = index();
        let (br, gz) = (page.br.as_ref().unwrap(), page.gzip.as_ref().unwrap());

        let out = get("/", &["gzip, br"], &[]);
        assert_eq!(out.header("Content-Encoding"), Some("br"));
        assert_eq!(out.body, br.body);
        assert_eq!(out.header("ETag"), Some(br.etag));

        let out = get("/", &["gzip, br;q=0"], &[]);
        assert_eq!(out.header("Content-Encoding"), Some("gzip"));
        assert_eq!(out.body, gz.body);
        assert_eq!(out.header("ETag"), Some(gz.etag));

        for ae in [&[][..], &["identity"], &["br;q=0, gzip;q=0"]] {
            let out = get("/", ae, &[]);
            assert_eq!(out.header("Content-Encoding"), None);
            assert_eq!(out.body, page.identity.body);
            assert_eq!(out.header("ETag"), Some(page.identity.etag));
        }
        for ae in [&[][..], &["br"]] {
            assert_eq!(get("/", ae, &[]).header("Vary"), Some("Accept-Encoding"));
        }
    }

    #[test]
    fn variants_are_smaller_and_well_formed() {
        let all = PAGES.iter().map(|(path, p)| (*path, p));
        for (path, p) in all.chain([("404", &NOT_FOUND)]) {
            let id = &p.identity;
            assert!(id.etag.starts_with('"') && id.etag.ends_with('"'), "{path}");
            if let Some(gz) = &p.gzip {
                assert!(gz.body.len() < id.body.len(), "{path}");
                assert!(gz.body.starts_with(&[0x1f, 0x8b]), "{path}");
                assert!(gz.etag.ends_with("-gz\""), "{path}");
            }
            if let Some(br) = &p.br {
                assert!(br.body.len() < id.body.len(), "{path}");
                assert!(br.etag.ends_with("-br\""), "{path}");
            }
        }
        // Real pages are big enough to compress.
        assert!(index().gzip.is_some() && index().br.is_some());
        // ETags are unique across the whole site.
        let mut tags: Vec<_> = PAGES
            .iter()
            .flat_map(|(_, p)| [Some(&p.identity), p.gzip.as_ref(), p.br.as_ref()])
            .flatten()
            .map(|v| v.etag)
            .collect();
        let n = tags.len();
        tags.sort_unstable();
        tags.dedup();
        assert_eq!(tags.len(), n);
    }

    #[test]
    fn ok_headers() {
        let out = get("/", &["br"], &[]);
        assert_eq!(out.status, 200);
        assert!(out.header("Content-Type").unwrap().starts_with("text/html"));
        assert_eq!(out.header("Cache-Control"), Some("no-cache"));
        let feed = get("/feed.xml?x", &[], &[]);
        assert_eq!(feed.status, 200);
        assert_eq!(feed.header("Cache-Control"), Some("no-cache"));
        assert!(feed.header("Content-Type").unwrap().contains("atom"));
    }

    #[test]
    fn if_none_match_gives_304() {
        let page = index();
        let br = page.br.as_ref().unwrap();
        let weak = format!("W/{}", br.etag);
        let list = format!("\"nope\", {}", br.etag);
        for inm in [br.etag, &weak, &list, "*"] {
            let out = get("/", &["br"], &[inm]);
            assert_eq!(out.status, 304, "{inm}");
            assert_eq!(out.header("ETag"), Some(br.etag));
            assert_eq!(out.header("Vary"), Some("Accept-Encoding"));
            assert_eq!(out.header("Cache-Control"), Some("no-cache"));
            assert_eq!(out.header("Content-Type"), None);
            assert_eq!(out.header("Content-Encoding"), None);
            // tiny_http sends no body for 304, only the 200's length.
            assert_eq!(out.body.len(), br.body.len());
        }
        // Several header lines.
        assert_eq!(get("/", &["br"], &["\"a\"", br.etag]).status, 304);
        // An ETag of another encoding or page does not match.
        for inm in [
            page.identity.etag,
            page.gzip.as_ref().unwrap().etag,
            "\"x\"",
            "",
            ",",
        ] {
            assert_eq!(get("/", &["br"], &[inm]).status, 200, "{inm}");
        }
        // HEAD behaves the same.
        let head = respond(Method::Head, "/", ["br"].into_iter(), [br.etag].into_iter());
        assert_eq!(head.status, 304);
    }

    #[test]
    fn head_matches_get() {
        for url in ["/", "/feed.xml", "/nope", "/posts"] {
            for ae in [&[][..], &["gzip"], &["br"]] {
                let g = get(url, ae, &[]);
                let h = respond(Method::Head, url, ae.iter().copied(), std::iter::empty());
                assert_eq!(g.status, h.status, "{url}");
                assert_eq!(g.headers(), h.headers(), "{url}");
                assert_eq!(g.body, h.body, "{url}");
            }
        }
    }

    #[test]
    fn not_found() {
        let out = get("/nope", &["br"], &["*"]);
        assert_eq!(out.status, 404);
        assert_eq!(out.header("ETag"), None);
        assert_eq!(out.header("Vary"), Some("Accept-Encoding"));
        assert_eq!(out.header("Cache-Control"), Some("no-cache"));
        let plain = get("/nope", &[], &[]);
        assert_eq!(plain.body, NOT_FOUND.identity.body);
        assert_eq!(plain.header("Content-Encoding"), None);
    }

    #[test]
    fn redirect_and_405() {
        let out = get("/posts?x", &["br"], &[]);
        assert_eq!(out.status, 301);
        assert_eq!(out.header("Location"), Some("/"));
        assert!(out.body.is_empty());

        let out = respond(Method::Other, "/", ["br"].into_iter(), ["*"].into_iter());
        assert_eq!(out.status, 405);
        assert_eq!(out.header("Allow"), Some("GET, HEAD"));
        assert_eq!(out.body, NOT_ALLOWED.identity.body);
        assert_eq!(out.header("Content-Encoding"), None);
    }

    #[test]
    fn security_headers_everywhere() {
        let outs = [
            get("/", &["br"], &[]),
            get("/", &[], &["*"]),
            get("/nope", &[], &[]),
            get("/posts", &[], &[]),
            respond(Method::Other, "/", std::iter::empty(), std::iter::empty()),
        ];
        for out in outs {
            assert!(out.headers().len() <= MAX_HEADERS);
            assert_eq!(out.header("X-Content-Type-Options"), Some("nosniff"));
            assert_eq!(out.header("Referrer-Policy"), Some("no-referrer"));
            let csp = out.header("Content-Security-Policy").unwrap();
            assert!(csp.starts_with("default-src 'none'") && !csp.contains("script"));
        }
    }
}
