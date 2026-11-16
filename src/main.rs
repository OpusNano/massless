//! massless: a tiny, fast Markdown blog server.

mod http;
#[cfg(test)]
mod render;
mod routes;

use http::respond;
use routes::Method;
use std::{env, num::NonZeroUsize, process::exit, sync::Arc, thread, time::Duration};
use tiny_http::{Header, Limits, Request, Response, Server, StatusCode};

/// Most open connections. Each costs a tiny_http thread and two file
/// descriptors, so this stays below the common soft limit of 1024 fds.
const MAX_CONNECTIONS: usize = 500;

fn main() {
    let listen = env::var("LISTEN").unwrap_or_else(|_| "0.0.0.0:8420".into());
    let threads = env_positive("THREADS").unwrap_or_else(|| {
        thread::available_parallelism()
            .map_or(2, NonZeroUsize::get)
            .max(2)
    });
    // Seconds a client may take to send a request head (also the keep-alive
    // idle timeout) and per blocked socket read or write.
    let timeout = env_positive("TIMEOUT").unwrap_or(10);

    let limits = Limits {
        timeout: Some(Duration::from_secs(timeout as u64)),
        max_connections: MAX_CONNECTIONS,
    };
    let server = match Server::http_with_limits(&listen, limits) {
        Ok(s) => Arc::new(s),
        Err(e) => fail(&format!("cannot listen on {listen}: {e}")),
    };
    match server.server_addr().to_ip() {
        Some(addr) => println!("massless listening on http://{addr} ({threads} threads)"),
        None => println!("massless listening on {listen} ({threads} threads)"),
    }

    let workers: Vec<_> = (0..threads)
        .map(|_| {
            let server = Arc::clone(&server);
            thread::spawn(move || {
                loop {
                    match server.recv() {
                        Ok(req) => handle(req),
                        // Can't happen with the patched tiny_http; exit so a
                        // supervisor restarts us rather than hanging.
                        Err(e) => fail(&format!("server stopped: {e}")),
                    }
                }
            })
        })
        .collect();
    for w in workers {
        let _ = w.join();
    }
}

/// A positive integer from env var `name`, `None` if unset; exits if invalid.
fn env_positive(name: &str) -> Option<usize> {
    let s = env::var(name).ok()?;
    match s.parse::<usize>() {
        Ok(n) if n > 0 => Some(n),
        _ => fail(&format!("{name} must be a positive integer, got {s:?}")),
    }
}

fn fail(msg: &str) -> ! {
    eprintln!("massless: {msg}");
    exit(1)
}

fn handle(req: Request) {
    let method = match req.method() {
        tiny_http::Method::Get => Method::Get,
        tiny_http::Method::Head => Method::Head,
        _ => Method::Other,
    };
    let values = |name: &'static str| {
        req.headers()
            .iter()
            .filter(move |h| h.field.equiv(name))
            .map(|h| h.value.as_str())
    };
    let out = respond(
        method,
        req.url(),
        values("Accept-Encoding"),
        values("If-None-Match"),
    );
    // tiny_http's API needs owned headers; all values are static ASCII.
    let headers = out
        .headers()
        .iter()
        .filter_map(|(n, v)| Header::from_bytes(n.as_bytes(), v.as_bytes()).ok())
        .collect();
    let body = out.body;
    let resp = Response::new(
        StatusCode(out.status),
        headers,
        body,
        Some(body.len()),
        None,
    )
    // Always send Content-Length, never chunked.
    .with_chunked_threshold(usize::MAX);
    // Errors here mean the client went away; nothing to do.
    let _ = req.respond(resp);
}
