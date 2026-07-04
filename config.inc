; === massless configuration ===
; Change these values and rebuild. No runtime config parsing.

%define SITE_TITLE       "massless"
%define BIND_ADDR        0x00000000        ; INADDR_ANY, network byte order
%define PORT             8420
%define HOT_RELOAD       1                 ; 0 = disable SSE, 1 = enable

%define MAX_POST_BYTES       1048576       ; 1 MiB max post file size
%define MAX_PUBLIC_BYTES     2097152       ; 2 MiB max public file size

%define MAX_POSTS            512           ; Max posts in index.
                                           ; Scan iterates full directory. Bounded-memory algorithm keeps
                                           ; newest MAX_POSTS unique-slug posts. Older posts skipped with
                                           ; stderr warning. NOTE: Zig version has no hard limit.

%define MAX_SSE_CLIENTS      32            ; Max concurrent SSE connections.
                                           ; Overflow returns 503.

%define RECV_TIMEOUT_SEC     5             ; Socket receive timeout in seconds.
                                           ; Slow clients dropped. Prevents slowloris in single-threaded loop.

%define TITLE_MAX_LEN        256           ; Max post title length. Titles > 255 bytes truncated at
                                           ; valid UTF-8 boundary, suffixed with "..." (three ASCII periods).

%define PATH_MAX_LEN         512           ; Max raw URL path length after ?/# stripping. Longer paths
                                           ; return 414 URI Too Long. Never truncated.

%define HEADER_MAX_LEN       4096          ; Max request header block. Larger returns 431.

%define RECV_BUF_SIZE        4096
%define SEND_BUF_SIZE        4096
%define RENDER_BUF_SIZE      8192
%define DIRENT_BUF_SIZE      4096
%define FILENAME_MAX          64
%define SLUG_MAX              64
