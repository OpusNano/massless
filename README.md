# massless

Tiny, fast Markdown blog server in Rust. `build.rs` renders `posts/` with
`templates/` into HTML, an index, an Atom feed and a 404 page, pre-compresses
them (brotli, gzip) and embeds them in the binary. At runtime it only looks up
the path and sends ready-made bytes.

## Posts

One file per post: `posts/YYYY-MM-DD-slug.md` (or
`posts/YYYY-MM-DD-HH-MM-SS-slug.md`; the time sets order and feed timestamp).
The URL is `/posts/<slug>`.

```markdown
---
title: The Rescue of Salyut 7
date: 2026-09-12
summary: Optional; shown on the index and used as the page description.
---

Markdown (GFM tables, footnotes, strikethrough, task lists).
```

`title` is required; `date` defaults to the file name date. A malformed post
fails the build. Preview: `cargo run --release` (re-renders on change), then
reload <http://localhost:8420>.

## Configuration

| Variable   | Default                | Meaning                                              |
|------------|------------------------|------------------------------------------------------|
| `LISTEN`   | `0.0.0.0:8420`         | Address to bind.                                     |
| `THREADS`  | CPU count (at least 2) | Worker threads.                                      |
| `TIMEOUT`  | `10`                   | Seconds per request head, idle keep-alive, read/write. |
| `SITE_URL` | empty (relative links) | **Build time** (Docker build arg): base URL for feed links. |

## Build and deploy

Prod is AMD EPYC-Rome: build for `x86-64-v2` at most, **never**
`target-cpu=native`. The `Dockerfile` builds a static musl binary on
`scratch`; CI tests every push and publishes `ghcr.io/opusnano/massless`
(`latest`, `sha-<short>`) from `master`, which production pulls.

```sh
cargo test --release
cargo clippy --release --all-targets -- -D warnings
```

`vendor/tiny_http` is tiny_http 0.12 with robustness fixes; see its
`PATCHES.md`.
