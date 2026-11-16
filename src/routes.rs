//! Static route table and request routing. Pure logic, no I/O.

/// A prebuilt response body with its content type.
pub struct Page {
    pub content_type: &'static str,
    pub body: &'static [u8],
}

const HTML: &str = "text/html; charset=utf-8";

/// Path -> page. Hardcoded for now; generated at build time later.
static ROUTES: &[(&str, Page)] = &[
    (
        "/",
        Page {
            content_type: HTML,
            body: b"<!doctype html><title>massless</title><h1>massless</h1>\n",
        },
    ),
    (
        "/hello",
        Page {
            content_type: "text/plain; charset=utf-8",
            body: b"hello\n",
        },
    ),
];

static NOT_FOUND: Page = Page {
    content_type: HTML,
    body: b"<!doctype html><title>Not found</title><h1>404 Not found</h1>\n",
};

static NOT_ALLOWED: Page = Page {
    content_type: "text/plain; charset=utf-8",
    body: b"405 Method Not Allowed\n",
};

/// Request methods we distinguish.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Method {
    Get,
    Head,
    Other,
}

/// What to send back. HEAD bodies are dropped by tiny_http itself.
#[derive(Debug, PartialEq, Eq)]
pub enum Reply {
    Ok(&'static Page),
    NotFound(&'static Page),
    MethodNotAllowed(&'static Page),
}

impl std::fmt::Debug for Page {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Page")
            .field("content_type", &self.content_type)
            .field("len", &self.body.len())
            .finish()
    }
}

impl PartialEq for Page {
    fn eq(&self, other: &Self) -> bool {
        std::ptr::eq(self, other)
    }
}
impl Eq for Page {}

/// Route a request. Query strings are ignored.
pub fn route(method: Method, url: &str) -> Reply {
    if method == Method::Other {
        return Reply::MethodNotAllowed(&NOT_ALLOWED);
    }
    let path = url.split_once('?').map_or(url, |(p, _)| p);
    match ROUTES.iter().find(|(p, _)| *p == path) {
        Some((_, page)) => Reply::Ok(page),
        None => Reply::NotFound(&NOT_FOUND),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn page(path: &str) -> &'static Page {
        &ROUTES.iter().find(|(p, _)| *p == path).unwrap().1
    }

    #[test]
    fn known_paths() {
        assert_eq!(route(Method::Get, "/"), Reply::Ok(page("/")));
        assert_eq!(route(Method::Get, "/hello"), Reply::Ok(page("/hello")));
    }

    #[test]
    fn query_is_ignored() {
        assert_eq!(route(Method::Get, "/?x=1"), Reply::Ok(page("/")));
        assert_eq!(route(Method::Get, "/hello?"), Reply::Ok(page("/hello")));
    }

    #[test]
    fn head_routes_like_get() {
        assert_eq!(route(Method::Head, "/hello"), Reply::Ok(page("/hello")));
        assert_eq!(route(Method::Head, "/nope"), Reply::NotFound(&NOT_FOUND));
    }

    #[test]
    fn unknown_is_404() {
        for url in ["/nope", "", "/hello/", "//", "/HELLO", "hello", "*"] {
            assert_eq!(
                route(Method::Get, url),
                Reply::NotFound(&NOT_FOUND),
                "{url}"
            );
        }
    }

    #[test]
    fn other_methods_are_405() {
        assert_eq!(
            route(Method::Other, "/"),
            Reply::MethodNotAllowed(&NOT_ALLOWED)
        );
        assert_eq!(
            route(Method::Other, "/nope"),
            Reply::MethodNotAllowed(&NOT_ALLOWED)
        );
    }
}
