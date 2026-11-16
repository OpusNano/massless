//! Shared helpers for the integration tests: run the real binary.

#![allow(dead_code)] // Not every test file uses every helper.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

/// The server process; killed on drop.
pub struct Server {
    child: Child,
    pub addr: SocketAddr,
}

impl Server {
    /// Starts the binary on a free port with a 1 s timeout.
    pub fn start() -> Server {
        let mut child = Command::new(env!("CARGO_BIN_EXE_massless"))
            .env("LISTEN", "127.0.0.1:0")
            .env("THREADS", "2")
            .env("TIMEOUT", "1")
            .stdout(Stdio::piped())
            .spawn()
            .expect("start server");
        let mut line = String::new();
        BufReader::new(child.stdout.take().unwrap())
            .read_line(&mut line)
            .unwrap();
        // "massless listening on http://ADDR (N threads)"
        let addr = line
            .split("http://")
            .nth(1)
            .and_then(|s| s.split_whitespace().next())
            .and_then(|s| s.parse().ok())
            .unwrap_or_else(|| panic!("no address in {line:?}"));
        Server { child, addr }
    }

    pub fn connect(&self) -> TcpStream {
        let s = TcpStream::connect(self.addr).unwrap();
        s.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        s
    }

    /// Sends raw bytes, returns everything until the server closes and how
    /// long that took.
    pub fn raw_bytes(&self, req: &[u8]) -> (Vec<u8>, Duration) {
        let mut s = self.connect();
        s.write_all(req).unwrap();
        let start = Instant::now();
        let mut out = Vec::new();
        // A reset after the response is fine; we only look at what arrived.
        let _ = s.read_to_end(&mut out);
        (out, start.elapsed())
    }

    pub fn raw(&self, req: &[u8]) -> (String, Duration) {
        let (out, took) = self.raw_bytes(req);
        (String::from_utf8_lossy(&out).into_owned(), took)
    }

    pub fn status(&self, req: &[u8]) -> String {
        let (resp, took) = self.raw(req);
        assert!(took < Duration::from_secs(5), "took {took:?}");
        resp.lines().next().unwrap_or("").to_string()
    }

    /// The server still answers a normal request.
    pub fn assert_alive(&self) {
        assert_eq!(
            self.status(b"GET / HTTP/1.1\r\nConnection: close\r\n\r\n"),
            "HTTP/1.1 200 OK"
        );
    }

    /// One request with `Connection: close` and extra header lines
    /// (`"Name: value"`), parsed.
    pub fn request(&self, method: &str, path: &str, headers: &[&str]) -> Resp {
        let mut req = format!("{method} {path} HTTP/1.1\r\nHost: test\r\nConnection: close\r\n");
        for h in headers {
            req.push_str(h);
            req.push_str("\r\n");
        }
        req.push_str("\r\n");
        let (out, _) = self.raw_bytes(req.as_bytes());
        Resp::parse(&out)
    }

    pub fn get(&self, path: &str, headers: &[&str]) -> Resp {
        self.request("GET", path, headers)
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// A parsed HTTP/1.1 response.
#[derive(Debug)]
pub struct Resp {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Resp {
    fn parse(raw: &[u8]) -> Resp {
        let end = raw
            .windows(4)
            .position(|w| w == b"\r\n\r\n")
            .unwrap_or_else(|| panic!("no header end in {:?}", String::from_utf8_lossy(raw)));
        let head = std::str::from_utf8(&raw[..end]).expect("ASCII head");
        let mut lines = head.split("\r\n");
        let status = lines
            .next()
            .and_then(|l| l.strip_prefix("HTTP/1.1 "))
            .and_then(|l| l.get(..3))
            .and_then(|c| c.parse().ok())
            .unwrap_or_else(|| panic!("bad status line in {head:?}"));
        let headers = lines
            .map(|l| {
                let (n, v) = l.split_once(':').expect("header line");
                (n.to_ascii_lowercase(), v.trim().to_string())
            })
            .collect();
        Resp {
            status,
            headers,
            body: raw[end + 4..].to_vec(),
        }
    }

    pub fn header(&self, name: &str) -> Option<&str> {
        let name = name.to_ascii_lowercase();
        self.headers
            .iter()
            .find(|(n, _)| *n == name)
            .map(|(_, v)| v.as_str())
    }

    pub fn text(&self) -> &str {
        std::str::from_utf8(&self.body).expect("UTF-8 body")
    }
}
