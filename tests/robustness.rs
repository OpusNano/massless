//! Malformed, oversized, truncated and slow requests against the real binary.

mod common;

use common::Server;
use std::io::{Read, Write};
use std::time::{Duration, Instant};

#[test]
fn bad_requests_get_an_error_and_close() {
    let srv = Server::start();
    let cases: [(&[u8], &str); 6] = [
        (b"\x00\x01 garbage\r\n\r\n", "400"),
        (b"GET / HTTP/1.1\r\nX: \xff\r\n\r\n", "400"),
        (b"GET / HTTP/2.0\r\n\r\n", "505"),
        (b"GET / HTTP/1.1\r\nExpect: nope\r\n\r\n", "417"),
        (
            &[b"GET /".as_slice(), &[b'a'; 20_000], b" HTTP/1.1\r\n\r\n"].concat(),
            "414",
        ),
        (
            &[
                b"GET / HTTP/1.1\r\n".as_slice(),
                &b"X: a\r\n".repeat(200),
                b"\r\n",
            ]
            .concat(),
            "431",
        ),
    ];
    for (req, code) in cases {
        let status = srv.status(req);
        assert!(
            status.starts_with(&format!("HTTP/1.1 {code} ")),
            "{status:?}"
        );
    }
    let huge_header = [
        b"GET / HTTP/1.1\r\nX: ".as_slice(),
        &[b'a'; 20_000],
        b"\r\n\r\n",
    ]
    .concat();
    assert!(srv.status(&huge_header).starts_with("HTTP/1.1 431 "));
    srv.assert_alive();
}

#[test]
fn bodies_are_not_read_and_end_the_connection() {
    let srv = Server::start();
    // A huge Content-Length used to make tiny_http allocate it and abort.
    let (resp, _) = srv.raw(b"GET / HTTP/1.1\r\nContent-Length: 99999999999999\r\n\r\nabc");
    assert!(resp.starts_with("HTTP/1.1 200 OK"), "{resp:?}");
    // A request hidden in a body is never served.
    let (resp, _) =
        srv.raw(b"GET / HTTP/1.1\r\nContent-Length: 20\r\n\r\nGET /nope HTTP/1.1\r\n\r\n");
    assert_eq!(resp.matches("HTTP/1.1 ").count(), 1, "{resp:?}");
    let (resp, _) = srv.raw(b"POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\nffffffff\r\nab");
    assert!(resp.starts_with("HTTP/1.1 405 "), "{resp:?}");
    srv.assert_alive();
}

#[test]
fn truncated_idle_and_slow_clients_time_out() {
    let srv = Server::start();
    // Truncated request: closed after the timeout, without blocking others.
    let mut stuck = srv.connect();
    stuck.write_all(b"GET / HTTP/1.1\r\nHo").unwrap();
    srv.assert_alive();
    let start = Instant::now();
    let mut buf = Vec::new();
    let _ = stuck.read_to_end(&mut buf);
    let took = start.elapsed();
    assert!(
        took < Duration::from_secs(3),
        "truncated request held {took:?}"
    );

    // Idle keep-alive connection: closed after the timeout.
    let (resp, took) = srv.raw(b"HEAD / HTTP/1.1\r\n\r\n");
    assert!(resp.starts_with("HTTP/1.1 200 OK"), "{resp:?}");
    assert!(
        took < Duration::from_secs(3),
        "idle connection held {took:?}"
    );

    // Byte-by-byte sender, each byte well within the socket timeout: the
    // per-request deadline still closes it.
    let mut slow = srv.connect();
    let start = Instant::now();
    for &b in b"GET / HTTP/1.1\r\nX-Slow: aaaaaaaaaaaaaaaaaaaaaaaa\r\n\r\n" {
        if slow.write_all(&[b]).is_err() {
            break;
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    let mut buf = Vec::new();
    let _ = slow.read_to_end(&mut buf);
    let took = start.elapsed();
    assert!(buf.is_empty(), "slow request was answered");
    assert!(took < Duration::from_secs(4), "slow client held {took:?}");
    srv.assert_alive();
}
