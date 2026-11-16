# tiny_http 0.12.0, patched for massless

Vendored from crates.io (first commit is the unchanged release) and used via
`[patch.crates-io]`. Every change is marked `Patched:` in the source.

- **Timeouts.** Accepted sockets get read/write timeouts, and each request's
  line and headers must arrive within the timeout (a deadline checked before
  every read, so byte-by-byte senders are cut off too). This is also the
  keep-alive idle timeout. Before: a truncated request held its connection
  and thread forever.
- **Connection limit.** At most `max_connections` open connections (one
  thread and two fds each); the accept loop waits for a free slot.
  Before: one thread per connection, unbounded.
- **Accept errors don't stop the server.** Before: the first accept error
  (e.g. EMFILE) ended the accept loop for good while the process kept running.
- **No panic when out of fds** (`try_clone().unwrap()`), and none when
  `peer_addr` fails.
- **Head limits.** Request line + headers max 16 KiB (414 / 431), max 100
  headers, non-ASCII head bytes give 400. Before: unbounded memory.
- **Request bodies are never drained**; any request with a body is the last
  on its connection. Before: dropping a request allocated its claimed
  `Content-Length` (a huge value aborted the process) and blocked the worker
  on slow uploads.
- **HTTP/2+ request line gives 505 and closes.** Before: writing the 505
  deadlocked the connection thread forever.
- API: `Limits`, `ServerConfig::limits`, `Server::http_with_limits`,
  `Server::from_listener_with_limits`. Upstream warnings are silenced.
