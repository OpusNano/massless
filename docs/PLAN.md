# massless: Rust rewrite plan

## Goal

Rewrite massless (a tiny Markdown blog server, Zig version tagged `zig-final`)
from scratch in Rust on branch `rust`. Same job: serve the posts in `posts/`
as a small, fast blog. All pages are rendered and compressed at build time;
the server only looks up and sends ready-made bytes.

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
- [ ] **3. Build-time rendering.** `build.rs` + shared render module:
  frontmatter parsing (with filename-date fallback), pulldown-cmark options,
  index, post pages, Atom feed, 404, `/posts` redirect, minimal templates.
  `cargo:rerun-if-changed` for `posts/` and `templates/`. The route table is
  generated.
- [ ] **4. HTTP semantics.** Build-time gzip + brotli variants, strong ETags,
  Accept-Encoding negotiation, If-None-Match → 304, HEAD, Cache-Control,
  Vary, security headers. Unit tests for negotiation and ETag/304.
- [ ] **5. Page design.** One small inlined CSS: typography, dark mode,
  mobile layout. Proper `<head>` (charset, viewport, title, description,
  feed link). Check page sizes (aim for an index well under 10 kB
  uncompressed).
- [ ] **6. Robustness.** Malformed, truncated and oversized requests, slow
  clients (read/write timeouts), bounded threads, no panics on input. Test
  with raw sockets (e.g. `printf 'GET / HTTP/1.1\r\nHo' | nc`) and add unit or
  integration tests where cheap.
- [ ] **7. Dev mode.** `dev` feature: mtime polling of `posts/` + `templates/`,
  in-memory re-render, SSE `/events` reload. Confirm that the default build
  pulls in none of it (`cargo tree`, binary size unchanged).
- [ ] **8. Ship.** Integration test (see Tests), multi-stage Dockerfile
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

## Report

(Filled in by step 8.)
