# massless

Zero-dependency blog server — Zig stdlib only. Serves Markdown posts as HTML with
optional hot-reload SSE. Single static binary, fits in a `FROM scratch` Docker image.

## Quick start

```sh
zig build run
```

Open http://0.0.0.0:8420

## Build & test

```sh
zig build test
zig build          # binary in zig-out/bin/
```

## Docker

```sh
docker build -t massless .
docker run --rm -p 8420:8420 -v ./posts:/posts -v ./public:/public massless
```

Image size: ~370 kB (`FROM scratch`).

## Posts

Place Markdown files in `posts/` with format:

```
YYYY-MM-DD-slug.md
```

Or with a timestamp:

```
YYYY-MM-DD-HH-MM-SS-slug.md
```

Slug: lowercase letters, digits, hyphens only. Max post size: 1 MiB.

Frontmatter (optional):

```
---
title: My Post
---
Body text here.
```

Posts are listed newest-first on the homepage. All valid posts are shown.
`/posts/<slug>` serves an individual post. `/posts` redirects to `/`.

## Static assets

Place files in `public/` — served at `/public/<path>`. Path traversal is
blocked. Max file size: 2 MiB. Oversized files return 413 Payload Too Large.

## Markdown support

- Headings (`#` through `######`)
- Paragraphs
- Bullet and ordered lists
- `*italic*` / `**bold**`
- Inline `` `code` ``
- Links `[text](url)` and images `![alt](url)`
- Thematic breaks (`---`)

HTML is escaped. Unsafe URL protocols (`javascript:`, `data:`, `vbscript:`) are blocked.

## Configuration

Edit `src/config.zig`:

```zig
pub const site_title = "massless";
pub const bind_addr = "0.0.0.0";
pub const port: u16 = 8420;
pub const hot_reload = true;
pub const max_post_bytes: usize = 1024 * 1024;
pub const max_public_file_bytes: usize = 2 * 1024 * 1024;
```

**Hot reload**: when `hot_reload = true`, the server polls `posts/` every 3s
and pushes changes to browsers via SSE on `/events`. Set `hot_reload = false`
to disable — `/events` returns 404 and no SSE script is injected.
