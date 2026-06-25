# massless

Zero-dependency blog server — Zig stdlib only. Serves Markdown posts as HTML with
hot-reload SSE. Single static binary, fits in a `FROM scratch` Docker image.

## Quick start

```sh
zig build run
```

Open http://0.0.0.0:8080

## Build & test

```sh
zig build test   # run 54 tests
zig build        # binary in zig-out/bin/
```

## Docker

```sh
docker build -t massless .
docker run --rm -p 8080:8080 -v ./posts:/posts -v ./public:/public massless
```

Image size: ~330 kB (`FROM scratch`). Runtime memory: ~2 MiB.

## Posts

Place Markdown files in `posts/` with the format:

```
YYYY-MM-DD-slug.md
```

Slug rules: lowercase letters, digits, hyphens only — no spaces or special chars.

Example: `2026-06-25-hello-world.md`

Frontmatter (optional):

```
---
title: My Post
---
Body text here.
```

Posts are listed newest-first. Homepage shows the 5 latest; `/posts` shows all.

## Static assets

Place files in `public/` — served at `/public/<path>`. Path traversal is blocked.

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
pub const port: u16 = 8080;
pub const hot_reload = true;
```

Hot reload: the server polls `posts/` every 3s and pushes changes to browsers via
SSE on `/events`. Set `hot_reload = false` to disable.
