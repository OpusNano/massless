//! massless: a tiny, fast Markdown blog server.

mod routes;

use routes::{Method, Reply, route};
use std::{env, num::NonZeroUsize, process::exit, sync::Arc, thread};
use tiny_http::{Header, Request, Response, Server, StatusCode};

fn main() {
    let listen = env::var("LISTEN").unwrap_or_else(|_| "0.0.0.0:8420".into());
    let threads = match env::var("THREADS") {
        Ok(s) => match s.parse::<usize>() {
            Ok(n) if n > 0 => n,
            _ => fail(&format!("THREADS must be a positive integer, got {s:?}")),
        },
        Err(_) => thread::available_parallelism()
            .map_or(2, NonZeroUsize::get)
            .max(2),
    };

    let server = match Server::http(&listen) {
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
                // recv() only fails when the server shuts down.
                while let Ok(req) = server.recv() {
                    handle(req);
                }
            })
        })
        .collect();
    for w in workers {
        let _ = w.join();
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
    let (status, page, allow) = match route(method, req.url()) {
        Reply::Ok(p) => (200, p, false),
        Reply::NotFound(p) => (404, p, false),
        Reply::MethodNotAllowed(p) => (405, p, true),
    };
    let mut headers = vec![header("Content-Type", page.content_type)];
    if allow {
        headers.push(header("Allow", "GET, HEAD"));
    }
    let resp = Response::new(
        StatusCode(status),
        headers,
        page.body,
        Some(page.body.len()),
        None,
    );
    // Errors here mean the client went away; nothing to do.
    let _ = req.respond(resp);
}

fn header(name: &'static str, value: &'static str) -> Header {
    Header {
        field: name.parse().expect("static header name"),
        value: value.parse().expect("static header value"),
    }
}
