//! Dev mode (`--features dev`): renders `posts/` and `templates/` in memory,
//! re-renders when their mtimes change and reloads open pages via SSE.
//! Uncompressed, no ETags, allocates freely. Not in the default build.

use crate::render::{self, HTML, Site};
use crate::routes::{Method, REDIRECTS};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tiny_http::{Header, Request, Response};

const POLL: Duration = Duration::from_millis(250);
/// SSE comment interval; a failed write ends a client's thread.
const PING: Duration = Duration::from_secs(15);
const CSP: &str = "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; img-src * data:";

/// One render of the site. `version` changes with every render (and across
/// restarts, since it is based on the clock).
struct State {
    version: u64,
    /// The site, or an HTML error page if rendering failed.
    site: Result<Site, Vec<u8>>,
}

pub struct Dev {
    root: PathBuf,
    state: Mutex<Arc<State>>,
    changed: Condvar,
}

/// Renders the site and starts the polling thread.
pub fn start() -> Arc<Dev> {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let dev = Arc::new(Dev {
        state: Mutex::new(Arc::new(build(&root, 0))),
        root,
        changed: Condvar::new(),
    });
    let watcher = Arc::clone(&dev);
    thread::spawn(move || watcher.watch());
    eprintln!(
        "massless: dev mode, watching {}/{{posts,templates}}",
        dev.root.display()
    );
    dev
}

impl Dev {
    fn current(&self) -> Arc<State> {
        Arc::clone(&self.state.lock().unwrap_or_else(|e| e.into_inner()))
    }

    /// Polls mtimes and re-renders on any change.
    fn watch(&self) {
        let mut last = fingerprint(&self.root);
        loop {
            thread::sleep(POLL);
            let now = fingerprint(&self.root);
            if now == last {
                continue;
            }
            last = now;
            let version = self.current().version;
            let next = Arc::new(build(&self.root, version));
            *self.state.lock().unwrap_or_else(|e| e.into_inner()) = next;
            self.changed.notify_all();
        }
    }

    pub fn handle(self: &Arc<Self>, req: Request) {
        let method = match req.method() {
            tiny_http::Method::Get => Method::Get,
            tiny_http::Method::Head => Method::Head,
            _ => Method::Other,
        };
        let path = req.url().split('?').next().unwrap_or("");
        if method == Method::Get && path == "/events" {
            let dev = Arc::clone(self);
            let mut w = req.into_writer();
            // Each SSE client gets its own thread, never a worker. If the
            // thread can't be created, the writer drops and the client
            // reconnects later.
            let _ = thread::Builder::new().spawn(move || {
                let _ = dev.events(&mut w);
            });
            return;
        }
        let state = self.current();
        let r = lookup(&state, method, path);
        let mut resp = Response::from_data(r.body.to_vec())
            .with_status_code(r.status)
            .with_chunked_threshold(usize::MAX);
        for (n, v) in [
            ("Content-Type", r.content_type),
            ("Cache-Control", "no-store"),
            ("Content-Security-Policy", CSP),
            ("Location", r.location),
        ] {
            if !v.is_empty()
                && let Ok(h) = Header::from_bytes(n, v)
            {
                resp.add_header(h);
            }
        }
        let _ = req.respond(resp);
    }

    /// Streams the current generation now and on every change, with
    /// keep-alive comments in between, until a write fails.
    fn events(&self, w: &mut dyn Write) -> io::Result<()> {
        w.write_all(
            b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\
              Cache-Control: no-store\r\nConnection: close\r\n\r\nretry: 500\n\n",
        )?;
        let mut sent = 0;
        loop {
            let state = self.state.lock().unwrap_or_else(|e| e.into_inner());
            let (state, _) = self
                .changed
                .wait_timeout_while(state, PING, |s| s.version == sent)
                .unwrap_or_else(|e| e.into_inner());
            let version = state.version;
            drop(state);
            if version == sent {
                w.write_all(b": ping\n\n")?;
            } else {
                write!(w, "data: {version}\n\n")?;
                sent = version;
            }
            w.flush()?;
        }
    }
}

/// A dev response.
#[derive(Debug, PartialEq, Eq)]
struct Reply<'a> {
    status: u16,
    content_type: &'static str,
    body: &'a [u8],
    location: &'static str,
}

fn lookup<'a>(state: &'a State, method: Method, path: &str) -> Reply<'a> {
    let reply = |status, content_type, body| Reply {
        status,
        content_type,
        body,
        location: "",
    };
    if method == Method::Other {
        return reply(
            405,
            "text/plain; charset=utf-8",
            b"405 Method Not Allowed\n",
        );
    }
    if let Some((_, to)) = REDIRECTS.iter().find(|(from, _)| *from == path) {
        return Reply {
            location: to,
            ..reply(301, "", b"")
        };
    }
    match &state.site {
        Err(page) => reply(500, HTML, page),
        Ok(site) => match site.pages.binary_search_by(|p| p.path.as_str().cmp(path)) {
            Ok(i) => reply(200, site.pages[i].content_type, &site.pages[i].body),
            Err(_) => reply(404, HTML, &site.not_found),
        },
    }
}

/// Renders the site with the reload script in every HTML page. On error,
/// logs it and keeps an error page that also reloads.
fn build(root: &Path, prev_version: u64) -> State {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64);
    let version = now.max(prev_version + 1);
    let script = format!(
        "<script>new EventSource(\"/events\").onmessage=e=>{{if(e.data!==\"{version}\")location.reload()}}</script>\n"
    );
    let site = render::load(&root.join("posts"), &root.join("templates"))
        .and_then(|input| render::render(&input, ""));
    let site = match site {
        Ok(mut site) => {
            for p in site.pages.iter_mut().filter(|p| p.content_type == HTML) {
                p.body = inject(&p.body, &script);
            }
            site.not_found = inject(&site.not_found, &script);
            eprintln!("massless: rendered {} pages", site.pages.len());
            Ok(site)
        }
        Err(e) => {
            eprintln!("massless: error: {e}");
            Err(format!(
                "<!doctype html><meta charset=\"utf-8\"><title>Build error</title>\
                 <h1>Build error</h1><pre>{}</pre>\n{script}",
                render::escape(&e)
            )
            .into_bytes())
        }
    };
    State { version, site }
}

/// Inserts `script` before the last `</body>`, or appends it.
fn inject(body: &[u8], script: &str) -> Vec<u8> {
    let at = body
        .windows(7)
        .rposition(|w| w == b"</body>")
        .unwrap_or(body.len());
    [&body[..at], script.as_bytes(), &body[at..]].concat()
}

/// Name, mtime and size of everything in `posts/` and `templates/` (and of
/// the directories themselves, which catches added and removed files).
fn fingerprint(root: &Path) -> Vec<(PathBuf, Option<SystemTime>, u64)> {
    let mut out = Vec::new();
    for dir in ["posts", "templates"] {
        let dir = root.join(dir);
        let entries = std::fs::read_dir(&dir).into_iter().flatten().flatten();
        for path in [dir.clone()].into_iter().chain(entries.map(|e| e.path())) {
            let meta = std::fs::metadata(&path).ok();
            let mtime = meta.as_ref().and_then(|m| m.modified().ok());
            out.push((path, mtime, meta.map_or(0, |m| m.len())));
        }
    }
    out.sort();
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn root() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
    }

    #[test]
    fn injects_script() {
        assert_eq!(inject(b"a</body>b</body>", "S"), b"a</body>bS</body>");
        assert_eq!(inject(b"ab", "S"), b"abS");
    }

    #[test]
    fn renders_and_routes() {
        let s = build(&root(), 0);
        assert!(s.version > 0);
        let page = |path| lookup(&s, Method::Get, path);
        let index = page("/");
        assert_eq!((index.status, index.content_type), (200, HTML));
        let html = std::str::from_utf8(index.body).unwrap();
        let script = format!("e.data!==\"{}\"", s.version);
        assert!(html.contains(&script) && html.ends_with("</script>\n</body>\n</html>\n"));
        let feed = page("/feed.xml");
        assert!(feed.status == 200 && !feed.body.windows(7).any(|w| w == b"<script"));
        assert_eq!(page("/nope").status, 404);
        assert_eq!(lookup(&s, Method::Head, "/").status, 200);
        assert_eq!(lookup(&s, Method::Other, "/").status, 405);
        let r = page("/posts");
        assert_eq!((r.status, r.location), (301, "/"));
    }

    #[test]
    fn errors_become_a_page() {
        let s = build(Path::new("/nonexistent"), 7);
        assert!(s.version > 7);
        let r = lookup(&s, Method::Get, "/");
        assert_eq!(r.status, 500);
        assert!(std::str::from_utf8(r.body).unwrap().contains("EventSource"));
    }

    #[test]
    fn fingerprint_sees_files() {
        let f = fingerprint(&root());
        assert!(f.iter().any(|(p, ..)| p.ends_with("templates/layout.html")));
        assert!(f.iter().all(|(_, t, _)| t.is_some()));
    }
}
