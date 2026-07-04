# massless

Zero-dependency blog server — x86-64 assembly, raw Linux syscalls only.

Serves Markdown posts as HTML with optional hot-reload SSE. Single static native binary (~15 KB).

## Quick start

```sh
./build.sh
./massless
```

Server listens on 0.0.0.0:8420 by default.
Open http://127.0.0.1:8420 locally.

## Build

```sh
nasm -f elf64 -O1 massless.asm -o massless.o
ld -nostdlib -static -T link.ld -e _start massless.o -o massless
strip massless
```

Requires NASM and GNU ld (binutils). Runtime: Linux x86-64 only.

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
Dates are validated (month lengths, leap years).

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
blocked. Max file size: 2 MiB.

## Markdown support

- Headings (`#` through `######`)
- Paragraphs
- Bullet and ordered lists
- `*italic*` / `**bold**`
- Inline `` `code` ``
- Links `[text](url)` and images `![alt](url)`
- Thematic breaks (`---`)

HTML is escaped. Unsafe URL protocols (`javascript:`, `data:`, `vbscript:`) are blocked.
Safe schemes (`http`, `https`, `mailto`) and relative paths are allowed.

## HTTP

Only GET and HEAD methods are accepted. All others return 405 and
the connection is closed immediately (body is not read).
Query strings are stripped before routing. HTML responses include:

- `Content-Security-Policy` (script-src depends on hot_reload mode)
- `X-Content-Type-Options: nosniff`
- `Referrer-Policy: no-referrer`

## Configuration

Edit `config.inc`:

| Define | Default | Description |
|--------|---------|-------------|
| `SITE_TITLE` | `"massless"` | Blog title |
| `BIND_ADDR` | `0x00000000` | INADDR_ANY |
| `PORT` | `8420` | Listen port |
| `HOT_RELOAD` | `1` | Enable SSE hot reload |
| `MAX_POST_BYTES` | `1048576` | Max post size (1 MiB) |
| `MAX_PUBLIC_BYTES` | `2097152` | Max public file size (2 MiB) |
| `MAX_POSTS` | `512` | Max posts in index |
| `MAX_SSE_CLIENTS` | `32` | Max concurrent SSE connections (503 when exceeded) |
| `RECV_TIMEOUT_SEC` | `5` | Socket receive timeout |
| `TITLE_MAX_LEN` | `256` | Max post title length |
| `PATH_MAX_LEN` | `512` | Max URL path length (414 URI Too Long when exceeded) |
| `HEADER_MAX_LEN` | `4096` | Max request header block (431 when exceeded) |

**Hot reload**: when `HOT_RELOAD = 1`, the server polls `posts/` every 3s
and pushes changes to browsers via SSE on `/events`. Set `HOT_RELOAD = 0`
to disable — `/events` returns 404 and no SSE script is injected.

## Assembly port limits

Exact parity claims apply to inputs within documented limits.
Inputs beyond these limits return proper HTTP error codes.
No undocumented deviations remain.

| Limit | Default | Behavior when exceeded |
|---|---|---|
| Keep-alive | Removed | `Connection: close` on every response |
| Max posts | 512 | Newest 512 unique-slug posts kept; older skipped with warning |
| Max SSE clients | 32 | 33rd client returns 503 Service Unavailable |
| Max title length | 256 bytes | Truncated at UTF-8 boundary + `"..."` |
| Max URL path | 511 bytes (PATH_MAX_LEN - 1) | Returns 414 URI Too Long |
| Max header block | 4 KB | Returns 431 Request Header Fields Too Large |

## Performance

| Metric | Value |
|--------|-------|
| Binary size | ~15 KB |
| Text section | ~12.6 KB |
| RoData section | ~2.3 KB |
| BSS | ~197 KB |
| Idle VmPeak | ~384 KB |
| Idle VmSize | ~376 KB |
| Idle RSS | ~60 KB |

## License

MIT
