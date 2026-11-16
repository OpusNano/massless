# massless

A tiny, fast Markdown blog server. Posts in `posts/` are rendered to HTML,
an index, an Atom feed and a 404 page **at build time**, pre-compressed
(brotli, gzip) and embedded in the binary. At runtime the server only looks
up the path and sends ready-made bytes: no file I/O, no Markdown, no
templates.

- No JavaScript, one small inlined stylesheet, dark mode.
- `Accept-Encoding` negotiation (br > gzip > identity), strong ETags with
  `304 Not Modified`, `HEAD`, security headers (CSP, nosniff, no-referrer).
- Timeouts and limits against slow or malformed clients.
- One ~740 kB static binary; the container image is just that binary.

## Writing posts

One file per post: `posts/YYYY-MM-DD-slug.md` (or
`posts/YYYY-MM-DD-HH-MM-SS-slug.md`; the time sets the order and feed timestamp). The slug
becomes the URL `/posts/<slug>`.

```markdown
---
title: The Rescue of Salyut 7
date: 2026-09-12
summary: Optional; shown on the index and used as the page description.
---

Markdown with GFM tables, footnotes, strikethrough, task lists and smart
punctuation.
```

`title` is required. `date` defaults to the date in the file name. A
malformed post fails the build with a message naming the file. Templates
and CSS are in `templates/`.

## Running

```sh
cargo run --release                        # http://0.0.0.0:8420
LISTEN=127.0.0.1:8080 THREADS=4 cargo run --release
```

Content is compiled in, so edit posts, then rebuild. URLs: `/`,
`/posts/<slug>`, `/feed.xml` (`/posts` redirects to `/`).

| Variable   | Default                   | Meaning                                                        |
|------------|---------------------------|----------------------------------------------------------------|
| `LISTEN`   | `0.0.0.0:8420`            | Address to bind. The bound address is printed on startup.      |
| `THREADS`  | CPU count (at least 2)    | Worker threads.                                                |
| `TIMEOUT`  | `10`                      | Seconds for a request head, an idle keep-alive, a socket read/write. |
| `SITE_URL` | empty (relative links)    | **Build time**: absolute base URL for feed links, e.g. `https://example.org`. |

## Dev mode

```sh
cargo run --features dev
```

Re-renders `posts/` and `templates/` in memory whenever they change and
reloads open browser tabs (server-sent events on `/events`). Pages are
uncompressed and carry a small reload script. A broken post shows an error
page until it is fixed. None of this is in the default build.

## Docker

```sh
docker build -t massless --build-arg SITE_URL=https://example.org .
docker run -d -p 8420:8420 massless
```

Multi-stage build: a static `x86_64-unknown-linux-musl` binary (CPU
baseline x86-64-v2), copied into an empty `scratch` image that runs as
UID 65532. Posts are baked in, so there are no volumes; rebuild the image
to publish.

## Development

```sh
cargo test --release                 # unit + integration tests (real binary)
cargo test --release --features dev
cargo clippy --release --all-targets -- -D warnings
```

`vendor/tiny_http` is tiny_http 0.12 with robustness fixes, see its
`PATCHES.md`. Design and history: [docs/PLAN.md](docs/PLAN.md).
