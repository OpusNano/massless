# massless: Rust rewrite plan

## Goal

Rewrite massless (a tiny Markdown blog server, Zig version tagged `zig-final`)
from scratch in Rust (developed on branch `rust`, now merged into `master`).
Same job: serve the posts in `posts/` as a small, fast blog. All pages are
rendered and compressed at build time; the server only looks up and sends
ready-made bytes.

Priorities, in order: **speed**, **performance**, **leanness** (small binary,
minimal per-request work, small pages). Do NOT port the Zig code. Keep it
lean and simple: the whole rewrite is a few hours of work, not days. No
gold-plating.

## Design spec (binding)

### Content and build-time rendering
- `build.rs` reads `posts/*.md`. Frontmatter between `---` lines with
  `title`, `date` (YYYY-MM-DD), optional `summary`.
- Filenames are `YYYY-MM-DD-slug.md` (optionally `YYYY-MM-DD-HH-MM-SS-slug.md`).
  The slug comes from the filename. If `date` is missing, use the filename
  date. The existing post `posts/2026-09-12-salyut-7-rescue.md` has only a
  `title`; it must stay byte-for-byte unchanged, so this fallback is required.
- A malformed post (no title, bad date, bad slug) fails the build with a
  clear message instead of being skipped silently.
- Render with pulldown-cmark: GFM tables, footnotes, strikethrough, task
  lists, smart punctuation. pulldown-cmark is a **build-dependency only**.
  It is not in the runtime binary (except under the `dev` feature, see below).
- Generate: index `/` (newest first: date, title, summary), post pages
  `/posts/<slug>`, an Atom feed `/feed.xml`, and a 404 page. `/posts`
  redirects to `/` (the old URLs keep working). Templates and CSS live in
  `templates/`. The rendering code lives in one module (e.g. `src/render.rs`)
  that `build.rs` pulls in with `#[path]` and that dev mode reuses.
- Pre-compress every response at build time: gzip (flate2 or zopfli) and
  brotli (the `brotli` crate, pure Rust, build-dep only). Keep a variant
  only if it is smaller than the identity body. Embed everything with
  `include_bytes!` from `OUT_DIR`. Precompute strong ETags, one per encoded
  variant (e.g. `"<hash>-br"`).

### Runtime
- `tiny_http` (default features off where possible, no TLS). Run a worker
  pool of `THREADS` threads (default: available_parallelism, min 2), each
  calling `server.recv()`. One keep-alive connection must never block other
  clients (the old massless had this bug).
- Each request is a static lookup: path → prebuilt response. Query strings
  are ignored. Set `Content-Type`, choose `Content-Encoding` from
  `Accept-Encoding` (br > gzip > identity, respect `q=0`), add
  `Vary: Accept-Encoding`, answer `If-None-Match` with 304, support HEAD,
  return 405 for other methods. Cache-Control: `no-cache` for HTML and the
  feed (always revalidate; a 304 is cheap). Security headers:
  `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, and a
  CSP without scripts (`default-src 'none'; style-src 'unsafe-inline'; img-src * data:`
  or similar).
- No file I/O and no per-request allocations in our own code (tiny_http
  allocates internally; don't fight it).
- Handle malformed or truncated requests gracefully: never hang or panic
  (the old massless logged `HttpRequestTruncated` and hung). Use timeouts so
  slow clients can't pin threads. Use `panic = "abort"`, so no code path on
  request input may panic.
- Config via env: `LISTEN` (default `0.0.0.0:8420`), `THREADS`. Print the
  bound address on startup (with `LISTEN=127.0.0.1:0` the tests can find
  the port).

### Pages
- No JavaScript. One small inlined `<style>`. Clean, readable typography
  (system font stack, ~65ch measure, good line height), mobile-friendly
  (viewport meta, fluid), dark mode via `prefers-color-scheme`. Keep pages
  small.

### Dev mode
- Cargo feature `dev` (off by default): poll `posts/` and `templates/` for
  changes (mtime polling, no watcher crate), re-render in memory, uncompressed,
  and reload the browser via SSE on `/events`. Serve each SSE client from its
  own thread, not a worker. Only dev pages get the small reload `<script>`.
  None of this code or its dependencies may be in the default build.

### Build, size, container
- Release profile: `lto = "fat"`, `codegen-units = 1`, `opt-level = 3`,
  `panic = "abort"`, `strip = true`. Also measure size with `opt-level = "z"`
  (`CARGO_PROFILE_RELEASE_OPT_LEVEL=z`).
- Target CPU: x86-64-v2 at most. **Never `target-cpu=native`**: prod is AMD
  EPYC-Rome and native builds have caused SIGILL there before.
- Multi-stage `Dockerfile`: build a static `x86_64-unknown-linux-musl` binary,
  then `FROM scratch`, `USER 65532:65532`, `EXPOSE 8420`. Content is baked
  in, so no volumes are needed. Docker is NOT installed here and must not be
  installed: the image is built on the prod host later. Instead, check the
  musl binary locally (`file`, `ldd` says it is not dynamic, it runs and
  serves pages).

### Tests
- Unit tests: routing, ETag/304, encoding negotiation, 404, HEAD.
- Integration test (`tests/`): start the real binary (`CARGO_BIN_EXE_massless`,
  `LISTEN=127.0.0.1:0`), then check every generated page with plain
  `std::net` (no extra dev-deps). Find slugs from `posts/` or the index; do
  not hardcode them. Also check feed, 404, 304, gzip/br, HEAD, `/posts`
  redirect, and a truncated/garbage request.

## Steps

Do exactly one step per session, in order. Each step is about 15–30 minutes.

- [x] **1. Clean slate + skeleton.** In one commit, remove all Zig
  code/tooling (`build.zig`, `src/*.zig`, `Dockerfile`, `.dockerignore`,
  `tools/integration_test.sh`, `public/`, Zig entries in `.gitignore`).
  Keep `posts/2026-09-12-salyut-7-rescue.md` unchanged, plus `LICENSE`,
  `docs/`, `CLAUDE.md`, `tools/loop.sh`. Replace README with a 3-line stub
  that points to this plan. Then, in a second commit, add a minimal Cargo
  skeleton: `Cargo.toml` (edition 2024, release profile as above),
  `src/main.rs`, `Cargo.lock`, and `.cargo/config.toml` only if needed for
  the CPU baseline.
- [x] **2. Static server.** tiny_http worker pool, `LISTEN`/`THREADS`, a static
  route table with a couple of hardcoded embedded responses, 404, 405, HEAD.
  Unit tests for routing. Check by hand that a held-open keep-alive
  connection doesn't block a second client.
- [x] **3. Build-time rendering.** `build.rs` + shared render module:
  frontmatter parsing (with filename-date fallback), pulldown-cmark options,
  index, post pages, Atom feed, 404, `/posts` redirect, minimal templates.
  `cargo:rerun-if-changed` for `posts/` and `templates/`. The route table is
  generated.
- [x] **4. HTTP semantics.** Build-time gzip + brotli variants, strong ETags,
  Accept-Encoding negotiation, If-None-Match → 304, HEAD, Cache-Control,
  Vary, security headers. Unit tests for negotiation and ETag/304.
- [x] **5. Page design.** One small inlined CSS: typography, dark mode,
  mobile layout. Proper `<head>` (charset, viewport, title, description,
  feed link). Check page sizes (aim for an index well under 10 kB
  uncompressed).
- [x] **6. Robustness.** Malformed, truncated and oversized requests, slow
  clients (read/write timeouts), bounded threads, no panics on input. Test
  with raw sockets (e.g. `printf 'GET / HTTP/1.1\r\nHo' | nc`) and add unit or
  integration tests where cheap.
- [x] **7. Dev mode.** `dev` feature: mtime polling of `posts/` + `templates/`,
  in-memory re-render, SSE `/events` reload. Confirm that the default build
  pulls in none of it (`cargo tree`, binary size unchanged).
- [x] **8. Ship.** Integration test (see Tests), multi-stage Dockerfile
  (musl, scratch, UID 65532, x86-64-v2), README (usage, env, dev mode,
  Docker), local musl binary check. Write the **Report** below: binary size
  at opt-level 3 vs z (musl), wrk against `/` with keep-alive and with
  `-H "Connection: close"` (e.g. `wrk -t2 -c50 -d10s`), test results, open
  items.

## Decisions

(Record technical decisions made during unattended sessions here, one line each.)

- No `.cargo/config.toml`: rustc's default `x86_64-unknown-linux-gnu` baseline is x86-64 (v1), already within the "v2 at most" limit.
- tiny_http 0.12 with default features off (no TLS); it suppresses HEAD bodies itself, so routing treats HEAD like GET.
- Routing lives in pure `src/routes.rs` (`route(Method, url) -> Reply`) so it is unit-testable without sockets; main.rs only maps it to tiny_http.
- Bad `THREADS` value exits with an error instead of silently using the default.
- pulldown-cmark 0.13 (default features off, `html` only) is a build-dep and a dev-dep (for render unit tests); `cargo tree -e normal` shows only tiny_http.
- Markdown headings are shifted down one level (`#` -> `<h2>`) so the post title is the page's only `<h1>`.
- Feed links use build-time env `SITE_URL` (default empty = site-relative links); Atom ids are `tag:massless,<date>:<slug>` so they don't depend on it.
- Frontmatter `date` wins over the file name date; a `HH-MM-SS` in the file name only sets the time (sort order, feed `updated`). Unknown frontmatter keys are ignored.
- Templates use one-pass `{{name}}` substitution; unknown placeholders fail the build. Site title is the constant `SITE_TITLE` in `src/render.rs`.
- Generated route table is sorted and looked up with binary search; `/posts` -> `/` is a 301 from a small static redirect list in `routes.rs` (`/posts/` stays 404).
- Gzip via `zopfli` (smaller than flate2, build-dep only), brotli quality 11 / lgwin 22; both build-deps only.
- ETag = 64-bit FNV-1a of the identity body in hex, plus `-gz`/`-br` for compressed variants; no hash crate.
- HTTP semantics live in pure `src/http.rs` (`respond() -> Out` with a fixed-size static header array); main.rs only converts to tiny_http headers (that conversion allocates; tiny_http's API needs owned headers).
- Accept-Encoding: br > gzip > identity among codings with q>0 (explicit entry wins over `*`, `x-gzip` = gzip); identity is always served, never 406.
- If-None-Match uses weak comparison against the selected variant's ETag, `*` matches; 304 omits Content-Type/Encoding but keeps Vary, ETag, Cache-Control.
- 304 and HEAD pass the real body to tiny_http, which sends only its `Content-Length` (equal to the 200's, as RFC 9110 allows) and no body.
- `with_chunked_threshold(usize::MAX)`: always `Content-Length`, never chunked; `Server: massless` replaces tiny_http's default.
- 404 is compressed and gets Vary + `no-cache` but no ETag/304; 301 and 405 are uncompressed with no caching headers.
- CSP: `default-src 'none'; style-src 'unsafe-inline'; img-src * data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`, on every response.
- Page description: frontmatter `summary`, else the first paragraph's plain text cut at a word boundary to 160 chars + "…"; index uses `SITE_DESCRIPTION`.
- CSS is hand-written compact (one rule per line) in `templates/style.css`, no build-time minifier; colors via custom properties, dark mode overrides them.
- `<link rel="icon" href="data:,">` stops browsers from requesting `/favicon.ico` (a 404) on every page; CSP already allows `data:` images.
- tiny_http 0.12 can't be made robust from outside (no timeouts, unbounded threads/heads, panics/aborts on input), so it is vendored in `vendor/tiny_http` with a small marked patch (`PATCHES.md`) via `[patch.crates-io]`, rather than replaced.
- New env `TIMEOUT` (seconds, default 10): per-socket read/write timeout and per-request head deadline (= keep-alive idle timeout); also lets tests run fast.
- Max 500 open connections (constant `MAX_CONNECTIONS`, 2 fds each, under a 1024-fd soft limit); extra clients wait in the listen backlog instead of being refused.
- Any request with a body (non-zero `Content-Length` or `Transfer-Encoding`) closes the connection after its response; bodies are never read or drained.
- If `server.recv()` ever fails, the process exits with an error (a supervisor restarts it) instead of leaving a worker silently gone.
- Dev mode: pulldown-cmark is an optional runtime dep enabled only by `dev`; `src/dev.rs` and the runtime `render` module are `cfg(feature = "dev")`, so the default binary is byte-identical.
- Dev mode reads `posts/` and `templates/` under `CARGO_MANIFEST_DIR` (works from any cwd with `cargo run --features dev`), polls mtimes + sizes every 250 ms.
- Dev reload: each render gets a clock-based version embedded in its pages; `/events` sends the current version on connect and on change (`: ping` every 15 s), and the page reloads if it differs, so reconnects and server restarts reload only when needed.
- SSE clients take the request via `Request::into_writer()` and run on their own thread; a render error is served as a 500 page (with the reload script) instead of exiting.
- Dev responses: uncompressed, `Cache-Control: no-store`, a CSP that allows the inline script and `connect-src 'self'`.
- Integration tests share a server helper in `tests/common/mod.rs`; `tests/site.rs` is `cfg(not(feature = "dev"))` (dev pages are uncompressed by design).
- tiny_http patch: `TCP_NODELAY` on accepted sockets (Nagle + delayed ACK cost ~40 ms per keep-alive response) rather than a bigger write buffer (no extra per-connection memory).
- Docker build stage `rust:1-alpine` with `--target x86_64-unknown-linux-musl` and `RUSTFLAGS=-C target-cpu=x86-64-v2` (applies to the binary only, not build.rs); `SITE_URL` is a build arg.
- `.dockerignore` is an allowlist (only the files the build needs), so `target/` and `.git` never enter the context.
- `STOPSIGNAL SIGKILL`: as PID 1 without a handler the binary ignores SIGTERM, and there is no state to flush.
- Release profile stays at `opt-level = 3`: `z` saves 86 kB (12 %) but is up to ~10 % slower on glibc.

## Notes

(One short subsection per finished step: what was done, anything surprising.)

### Step 1
- Removed all Zig code/tooling, `public/`, Dockerfile and Zig `.gitignore` entries; README is a stub.
- Cargo skeleton (edition 2024, release profile per spec, no deps). Toolchain: rustc 1.100.0. Empty release binary: 289 kB.

### Step 2
- Worker pool of `THREADS` threads on a shared `Arc<Server>` calling `recv()`; `LISTEN`/`THREADS` env; prints bound address.
- Hardcoded routes `/`, `/hello`; 404, 405 (+ `Allow: GET, HEAD`), HEAD; query strings ignored. 5 routing unit tests.
- Manual check, `THREADS=2`: 3 held-open keep-alive connections, 4 more curl requests still answered in <1 ms each. tiny_http reads each connection on its own internal pool thread (that pool grows as needed), so idle connections don't use up our workers.
- A truncated request (`GET / HTTP/1.1\r\nHo`) currently waits forever on its connection (others are unaffected); timeouts are step 6.
- Release binary: 563 kB.

### Step 3
- `src/render.rs` (pulled into `build.rs` via `#[path]`, into the binary only for tests): file name + frontmatter parsing with date fallback and validation, pulldown-cmark (tables, footnotes, strikethrough, task lists, smart punctuation), index, post pages, Atom feed, 404. `templates/layout.html` + `templates/style.css` (minimal; design is step 5).
- `build.rs` writes each body to `OUT_DIR` and generates `site.rs` (`PAGES`, `NOT_FOUND`) with `include_bytes!`; `routes.rs` includes it. `rerun-if-changed` on `posts`, `templates`, `src/render.rs`; adding/removing a post rebuilds.
- Malformed post fails the build, e.g. `error: massless: posts/2026-10-01-bad.md: missing `title` in frontmatter`.
- 15 unit tests (render + routing). By hand: `/` 626 B, post 6.8 kB, feed 6.9 kB, `/posts` 301, 404 page. Release binary: 579 kB.

### Step 4
- `build.rs` writes identity, `-gz` (zopfli) and `-br` variants per page (kept only if smaller) and strong ETags into the generated table; `src/http.rs` does negotiation, 304, Cache-Control, Vary and security headers. 25 unit tests total.
- Sizes (identity / gzip / br): index 626 / 383 / 238 B, post 6847 / 3102 / 2386 B, feed 6948 / 3056 / 2395 B, 404 581 / 370 / 211 B.
- By hand with curl: br/gzip/identity picked correctly, gzip decodes back to the identity body (no brotli CLI here to decode br by hand), 304 with `If-None-Match`, HEAD, 404, 301, 405. A keep-alive connection stays in sync after a 304 and a HEAD (bodies are not sent). `cargo tree -e normal` still shows only tiny_http. Release binary: 602 kB.
### Step 5
- `templates/style.css`: system font stack, 68ch measure, 1.65 line height, light/dark palettes via `prefers-color-scheme`, fluid padding, styles for code, tables (scroll on narrow screens), blockquotes, footnotes and the index list. Layout gets a footer with the feed link and an empty data: favicon.
- Sizes (identity / gzip / br): index 2330 / 1136 / 903 B, post 8683 / 3862 / 3087 B, 404 2274 / 1113 / 863 B; a test keeps the index under 8 kB. No browser is installed here, so the look was not checked visually. Release binary: 611 kB.

### Step 6
- Probed with raw sockets; found in tiny_http 0.12: a huge `Content-Length` aborted the process (it allocated that much when dropping the request); a truncated, idle or byte-by-byte request held its connection and thread forever; an `HTTP/2.0` request line deadlocked its connection thread forever; with fds exhausted (`prlimit --nofile=40`) the accept loop stopped for good and the process stayed up refusing every connection; unbounded threads and header sizes.
- Fixed in the vendored, patched tiny_http (see Decisions and `vendor/tiny_http/PATCHES.md`). Now: 400 garbage / non-ASCII, 414 long URI, 431 big or many headers, 505 HTTP/2+, 417 bad `Expect`, all then close; truncated, idle and slow requests are closed after `TIMEOUT`; the server keeps serving after fd exhaustion; 700 held connections → ~506 server threads, and a new client is still served.
- `tests/robustness.rs`: 3 integration tests on the real binary with `TIMEOUT=1` (~3.5 s). Total 29 tests.
- A 1 s connect stall at ~160 rapid connections also happens with the unpatched build (client SYN retry), not a regression.
- Open: a client that stops reading can hold a worker for up to `TIMEOUT` per blocked write (responses are ≤ ~10 kB, so only when pipelining); tiny_http's own error responses (400/414/431/505) lack our security headers and say `Server: tiny-http`. Release binary: 612 kB.

### Step 7
- `cargo run --features dev`: renders in memory, injects `<script>` (EventSource) before `</body>` of HTML pages only (not the feed), re-renders on change. 4 unit tests (`cargo test --release --features dev`: 30 + 3 pass; clippy clean with and without `dev`).
- By hand with `THREADS=2`: 3 open `/events` clients and `/` is still served; adding a post shows it and pushes a new version to all clients; a broken post gives a 500 error page and the log line; deleting it recovers.
- Default build: same SHA-256 as before the step (612 224 B), `cargo tree -e normal` has no pulldown-cmark, no `EventSource` strings. Dev binary: 1.04 MB.
- Edition 2024 reserves `gen`, hence `version`. Dev responses still say `Server: tiny-http (Rust)`; harmless.

## Report

Measured 2026-11-16 on the dev box (4 CPUs, rustc 1.100.0), server and wrk
on the same host, so absolute numbers are only indicative.

**Binary size** (stripped, fat LTO, `panic = "abort"`):

| target                          | opt-level 3 | opt-level z |
|---------------------------------|------------:|------------:|
| x86_64-unknown-linux-musl (v2)  |   738 088 B |   652 072 B |
| x86_64-unknown-linux-gnu (v1)   |   612 304 B |   526 992 B |

The musl binary is a static PIE (`ldd`: statically linked, no `PT_INTERP`),
has no AVX (`ymm`/`zmm`) instructions, runs and serves all pages (RSS ~1 MB
idle). `file` is not installed; checked with `readelf`/`ldd`/`objdump`.

**wrk -t2 -c50 -d10s on `/`** (identity body, 2330 B), req/s:

| binary              | keep-alive  | `Connection: close` |
|---------------------|------------:|--------------------:|
| gnu, opt 3          | 206k – 209k |                 68k |
| gnu, opt z          |        187k |                   – |
| musl, opt 3         |   61k – 85k |                 39k |
| musl, opt z         |   81k – 89k |                 39k |
| gnu, before NODELAY |         585 |                 66k |

Keep-alive latency avg ~0.17 ms (gnu). With `Connection: close` wrk counts
every server close as a "read" socket error; a raw client sees a clean FIN
and no resets, all responses are 200. The 585 req/s row is the 40 ms
Nagle/delayed-ACK stall found in this step and fixed in tiny_http.

**Tests:** `cargo test --release`: 26 unit + 3 robustness + 4 site
integration = 33 pass (~4.5 s). `--features dev`: 30 unit + 3 robustness
(site tests skipped). Clippy clean with and without `dev`.

**Open items**
- musl's allocator makes the prod (musl) binary ~2.5× slower than glibc
  on keep-alive; tiny_http allocates per request. A faster global allocator
  for the musl build (e.g. mimalloc) is the likely fix; not done (adds a C
  dependency) and should be measured on the EPYC host first.
- The Docker image was not built (no Docker here); the build stage was
  simulated by building from a copy holding only the copied files.
- tiny_http's own error responses (400/414/431/505) lack our security
  headers and say `Server: tiny-http`; dev responses too.
- A client that stops reading can hold a worker for up to `TIMEOUT` per
  blocked write (only when pipelining; responses are ≤ ~10 kB).
- Responses over 1 KiB still go out as two writes (headers, body); fine
  with NODELAY, one write would save a syscall and a packet.
- The page design was never checked in a real browser.

### Step 8
- `tests/site.rs`: real binary, `std::net` only; slugs from `posts/`, every post, index links, feed, 404, 301, 405, gzip/br, per-variant ETag/304, HEAD, pipelining, garbage and truncated requests. Server helper moved to `tests/common/mod.rs`.
- wrk found keep-alive capped at 585 req/s (40 ms each): tiny_http writes headers and bodies over 1 KiB separately and Nagle waited for the delayed ACK. Fixed with `TCP_NODELAY` in the vendored tiny_http → ~206k req/s.
- `Dockerfile` + allowlist `.dockerignore`; README rewritten (posts, env, dev mode, Docker, tests). Numbers and open items in **Report**.
