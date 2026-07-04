; === massless.asm — zero-dependency blog server in x86-64 assembly ===
; Build: nasm -f elf64 -O1 massless.asm -o massless.o && ld -nostdlib -static -T link.ld -e _start massless.o -o massless

%include "config.inc"
%include "sys.inc"

BITS 64
default rel

section .text
global _start

; ============================================================
; Output sink
; ============================================================
; output_mode: 0=socket, 1=count

write_byte:
    cmp byte [output_mode], 1
    jne .socket
    inc qword [byte_count]
    ret
.socket:
    push rdi
    push rsi
    mov rdi, [send_buf_ptr]
    mov [rdi], al
    inc qword [send_buf_ptr]
    mov rdi, [send_buf_ptr]
    sub rdi, send_buf
    cmp rdi, SEND_BUF_SIZE - 512
    jb  .done
    call flush_send_buf
.done:
    pop rsi
    pop rdi
    ret

write_str:
    cmp byte [output_mode], 1
    jne .socket
    add [byte_count], rdx
    ret
.socket:
    push r12
    push r13
    push r14
    push rsi
    push rdi
    mov r12, rsi
    mov r13, rdx
.loop:
    test r13, r13
    jz  .done
    mov rsi, r12
    mov rdi, [send_buf_ptr]
    mov rcx, r13
    mov rax, send_buf + SEND_BUF_SIZE
    sub rax, rdi
    cmp rcx, rax
    jbe .copy
    mov rcx, rax
.copy:
    mov r14, rcx
    rep movsb
    mov [send_buf_ptr], rdi
    sub r13, r14
    add r12, r14
    mov rdi, [send_buf_ptr]
    sub rdi, send_buf
    cmp rdi, SEND_BUF_SIZE - 512
    jb  .loop
    call flush_send_buf
    jmp .loop
.done:
    pop rdi
    pop rsi
    pop r14
    pop r13
    pop r12
    ret

flush_send_buf:
    mov rdi, [send_buf_ptr]
    sub rdi, send_buf
    jz  .done
    push rsi
    push rdx
    mov edx, edi
    mov edi, [client_fd]
    mov esi, send_buf
    mov eax, SYS_write
    syscall
    pop rdx
    pop rsi
    mov qword [send_buf_ptr], send_buf
.done:
    ret

%macro WRITE_STR 2
    push rsi
    push rdx
    lea rsi, [rel %1]
    mov edx, %2
    call write_str
    pop rdx
    pop rsi
%endmacro

; ---- HTML escaping ----

html_escape_byte:
    cmp al, '<'
    je  .lt
    cmp al, '>'
    je  .gt
    cmp al, '&'
    je  .amp
    cmp al, '"'
    je  .quot
    call write_byte
    ret
.lt:
    push rax
    WRITE_STR lt_ent, 4
    pop rax
    ret
.gt:
    push rax
    WRITE_STR gt_ent, 4
    pop rax
    ret
.amp:
    push rax
    WRITE_STR amp_ent, 5
    pop rax
    ret
.quot:
    push rax
    WRITE_STR quot_ent, 6
    pop rax
    ret

html_escape_str:
    push r12
    push r13
    mov r12, rsi
    mov r13, rdx
.loop:
    test r13, r13
    jz  .done
    mov al, [r12]
    call html_escape_byte
    inc r12
    dec r13
    jmp .loop
.done:
    pop r13
    pop r12
    ret

; ---- Easy syscall wrappers ----

read_fd:
    mov eax, SYS_read
    syscall
    ret

; ---- Response writers ----

write_status_ok:
    WRITE_STR http_ok, http_ok_len
    ret

write_ct_html:
    WRITE_STR ct_html, ct_html_len
    ret

write_cl_hdr:
    push rax
    WRITE_STR cl_prefix, 16
    pop rax
    push rbx
    push r12
    mov rbx, rax
    sub rsp, 32
    mov rdi, rsp
    add rdi, 28
    mov byte [rdi], 0
    dec rdi
    mov rax, rbx
    mov rcx, 10
.conv:
    xor edx, edx
    div rcx
    add dl, '0'
    mov [rdi], dl
    dec rdi
    test rax, rax
    jnz .conv
    inc rdi
    mov rsi, rdi
    mov rdx, rsp
    add rdx, 28
    sub rdx, rdi
    call write_str
    WRITE_STR crlf_str, 2
    add rsp, 32
    pop r12
    pop rbx
    ret

write_security:
    WRITE_STR xcto_hdr, xcto_hdr_len
    WRITE_STR rp_hdr, rp_hdr_len
    ret

write_csp:
    cmp byte [HOT_RELOAD_BYTE], 1
    je  .inline
    WRITE_STR csp_none, csp_none_len
    ret
.inline:
    WRITE_STR csp_inline, csp_inline_len
    ret

write_conn_close:
    WRITE_STR conn_close_hdr, conn_close_hdr_len
    ret

write_html_headers:
    push rax
    call write_status_ok
    call write_ct_html
    pop rax
    call write_cl_hdr
    call write_security
    call write_csp
    call write_conn_close
    WRITE_STR crlf_str, 2
    ret

write_html_404_headers:
    push rax
    WRITE_STR http_404, http_404_len
    call write_ct_html
    pop rax
    call write_cl_hdr
    call write_security
    call write_csp
    call write_conn_close
    WRITE_STR crlf_str, 2
    ret

send_404:
    WRITE_STR n404, n404_len
    ret

send_405:
    WRITE_STR raw405, raw405_len
    call flush_send_buf
    ret

send_303:
    WRITE_STR raw303, raw303_len
    call flush_send_buf
    ret

send_414:
    WRITE_STR raw414, raw414_len
    call flush_send_buf
    ret

send_431:
    WRITE_STR raw431, raw431_len
    call flush_send_buf
    ret

send_503:
    WRITE_STR raw503, raw503_len
    call flush_send_buf
    ret

; ============================================================
; String helpers
; ============================================================

strlen_cdecl:
    push rdi
    xor eax, eax
    mov rcx, -1
    repne scasb
    not rcx
    dec rcx
    mov rax, rcx
    pop rdi
    ret

strcmp_simple:
.loop:
    mov al, [rdi]
    mov cl, [rsi]
    cmp al, cl
    jne .done
    test al, al
    jz  .done
    inc rdi
    inc rsi
    jmp .loop
.done:
    ret

; ============================================================
; Post filename validation
; ============================================================

days_in_month:
    cmp al, 2
    je  .feb
    cmp al, 4
    je  .thirty
    cmp al, 6
    je  .thirty
    cmp al, 9
    je  .thirty
    cmp al, 11
    je  .thirty
    mov al, 31
    ret
.thirty:
    mov al, 30
    ret
.feb:
    mov eax, edx
    push rdx
    mov ecx, 400
    xor edx, edx
    div ecx
    test edx, edx
    jz  .leap
    pop rdx
    mov eax, edx
    push rdx
    mov ecx, 100
    xor edx, edx
    div ecx
    test edx, edx
    jz  .not_leap
    pop rdx
    mov eax, edx
    push rdx
    mov ecx, 4
    xor edx, edx
    div ecx
    test edx, edx
    jnz .not_leap
.leap:
    pop rdx
    mov al, 29
    ret
.not_leap:
    pop rdx
    mov al, 28
    ret

; parse_dec: rsi=ptr, cl=digits → eax=value, ZF=1 on success
parse_dec:
    xor eax, eax
.loop:
    test cl, cl
    jz  .ok
    mov dl, [rsi]
    cmp dl, '0'
    jb  .bad
    cmp dl, '9'
    ja  .bad
    imul eax, 10
    sub dl, '0'
    movzx edx, dl
    add eax, edx
    inc rsi
    dec cl
    jmp .loop
.ok:
    cmp eax, eax
    ret
.bad:
    mov eax, 1
    cmp eax, 0
    ret

; parse_timestamped_filename: rsi=name, rdx=len
; On success: sets [ts_year],[ts_month]... , r12=slug_ptr, r13=slug_len, ZF=1
; On failure: ZF=0
parse_timestamped_filename:
    push rbx
    cmp rdx, 15
    jb  .fail
    cmp byte [rsi+rdx-3], '.'
    jne .fail
    cmp byte [rsi+rdx-2], 'm'
    jne .fail
    cmp byte [rsi+rdx-1], 'd'
    jne .fail
    sub rdx, 3
    mov rbx, rdx        ; save length without .md for later use
    cmp rdx, 12
    jb  .fail
    cmp byte [rsi+4], '-'
    jne .fail
    cmp byte [rsi+7], '-'
    jne .fail
    cmp byte [rsi+10], '-'
    jne .fail

    push rsi
    mov cl, 4
    call parse_dec
    pop rsi
    jne .fail
    mov [ts_year], ax

    push rsi
    lea rsi, [rsi+5]
    mov cl, 2
    call parse_dec
    pop rsi
    jne .fail
    cmp al, 1
    jb  .fail
    cmp al, 12
    ja  .fail
    mov [ts_month], al

    push rsi
    lea rsi, [rsi+8]
    mov cl, 2
    call parse_dec
    pop rsi
    jne .fail
    cmp al, 1
    jb  .fail
    mov [ts_day], al
    mov dl, [ts_month]
    push rdx
    movzx edx, word [ts_year]
    mov al, [ts_month]
    call days_in_month
    mov dl, [ts_day]
    cmp dl, al
    pop rdx
    ja  .fail

    cmp rbx, 20
    jb  .date_only
    cmp byte [rsi+13], '-'
    jne .date_only
    cmp byte [rsi+16], '-'
    jne .date_only
    cmp byte [rsi+19], '-'
    jne .date_only

    push rsi
    lea rsi, [rsi+11]
    mov cl, 2
    call parse_dec
    pop rsi
    jne .fail
    cmp al, 23
    ja  .fail
    mov [ts_hour], al

    push rsi
    lea rsi, [rsi+14]
    mov cl, 2
    call parse_dec
    pop rsi
    jne .fail
    cmp al, 59
    ja  .fail
    mov [ts_min], al

    push rsi
    lea rsi, [rsi+17]
    mov cl, 2
    call parse_dec
    pop rsi
    jne .fail
    cmp al, 59
    ja  .fail
    mov [ts_sec], al

    mov byte [ts_has_time], 1
    lea r12, [rsi+20]
    mov r13, rbx
    sub r13, 20
    jmp .check_slug

.date_only:
    mov byte [ts_hour], 0
    mov byte [ts_min], 0
    mov byte [ts_sec], 0
    mov byte [ts_has_time], 0
    lea r12, [rsi+11]
    mov r13, rbx
    sub r13, 11

.check_slug:
    cmp r13, 1
    jb  .fail
    xor eax, eax
.slug_loop:
    cmp rax, r13
    je  .slug_ok
    mov cl, [r12+rax]
    cmp cl, 'a'
    jb  .chk_num
    cmp cl, 'z'
    jbe .slug_next
    jmp .fail
.chk_num:
    cmp cl, '0'
    jb  .chk_hyphen
    cmp cl, '9'
    jbe .slug_next
    jmp .fail
.chk_hyphen:
    cmp cl, '-'
    jne .fail
.slug_next:
    inc rax
    jmp .slug_loop
.slug_ok:
    cmp eax, eax
    pop rbx
    ret
.fail:
    mov eax, 1
    cmp eax, 0         ; ZF=0
    pop rbx
    ret

; is_safe_slug: rsi=slug, rdx=len → ZF=1 if safe
is_safe_slug:
    test rdx, rdx
    jz  .no
    xor eax, eax
.loop:
    cmp rax, rdx
    je  .yes
    mov cl, [rsi+rax]
    cmp cl, 'a'
    jb  .chk_num
    cmp cl, 'z'
    jbe .next
    jmp .no
.chk_num:
    cmp cl, '0'
    jb  .chk_h
    cmp cl, '9'
    jbe .next
    jmp .no
.chk_h:
    cmp cl, '-'
    jne .no
.next:
    inc rax
    jmp .loop
.yes:
    cmp eax, eax
    ret
.no:
    mov eax, 1
    cmp eax, 0
    ret

; ============================================================
; Post index (BSS arrays)
; ============================================================
; post_count: number of active posts
; post_sorted[i] = index into arrays, sorted newest-first
; post_fnames[i*FN_LEN] = filename (64 bytes)
; post_titles[i*TITLE_LEN] = title (256 bytes)
; post_ts_year[i*2], post_ts_month[i] etc.

; ts_cmp_newer: rdi=idx_a, rsi=idx_b → ZF=1 if a newer than b
; newest-first: year desc, month desc, day desc, hour desc, min desc, sec desc, slug asc
ts_cmp_newer:
    push r12
    push r13
    push r14
    movzx r12d, word [post_ts_year+rdi*2]
    movzx r13d, word [post_ts_year+rsi*2]
    cmp r12d, r13d
    jg  .yes
    jl  .no

    movzx r12d, byte [post_ts_month+rdi]
    movzx r13d, byte [post_ts_month+rsi]
    cmp r12d, r13d
    jg  .yes
    jl  .no

    movzx r12d, byte [post_ts_day+rdi]
    movzx r13d, byte [post_ts_day+rsi]
    cmp r12d, r13d
    jg  .yes
    jl  .no

    movzx r12d, byte [post_ts_hour+rdi]
    movzx r13d, byte [post_ts_hour+rsi]
    cmp r12d, r13d
    jg  .yes
    jl  .no

    movzx r12d, byte [post_ts_min+rdi]
    movzx r13d, byte [post_ts_min+rsi]
    cmp r12d, r13d
    jg  .yes
    jl  .no

    movzx r12d, byte [post_ts_sec+rdi]
    movzx r13d, byte [post_ts_sec+rsi]
    cmp r12d, r13d
    jg  .yes
    jl  .no

    mov r14, rdi
    shl r14, 6
    mov r12, rsi
    shl r12, 6
    lea rdi, [post_fnames+r14]
    lea rsi, [post_fnames+r12]
    call strcmp_simple
    jb  .yes
    jmp .no
.yes:
    pop r14
    pop r13
    pop r12
    cmp eax, eax
    ret
.no:
    pop r14
    pop r13
    pop r12
    mov eax, 1
    cmp eax, 0
    ret

; find_slug_by_name: compare slug (rsi,rdx) against post_fnames entry
; uses the slug extracted from filename: skip date prefix, match slug + ".md"
; For simplicity, compare entire filenames
; write_decimal: rax=uint → writes digits to rdi, returns rax=start ptr
write_decimal:
    push rbx
    push r12
    mov rbx, rdi
    add rdi, 20
    mov byte [rdi], 0
    dec rdi
    mov ecx, 10
.wdlp:
    xor edx, edx
    div rcx
    add dl, '0'
    mov [rdi], dl
    dec rdi
    test rax, rax
    jnz .wdlp
    inc rdi
    mov rax, rdi
    pop r12
    pop rbx
    ret

; ---- Post index helpers ----

; find_post_by_slug: rsi=slug_ptr, rdx=slug_len → rax=post index or -1
; Uses post_sorted to iterate; compares slug extracted from filename
find_post_by_slug:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rsi        ; requested slug ptr
    mov r14, rdx        ; requested slug len
    mov r15, [post_count]
    xor r13d, r13d      ; loop counter
.loop:
    cmp r13, r15
    jae .nf
    mov rax, [post_sorted+r13*8]  ; original post index
    mov r12, rax
    mov rdi, r12
    shl rdi, 6
    lea rsi, [post_fnames+rdi]
    mov rdi, rsi
    call strlen_cdecl
    mov rdx, rax
    push r13
    call parse_timestamped_filename
    mov r8, r13
    pop r13
    jne .next
    ; r12=slug_ptr, r8=slug_len from filename
    cmp r8, r14
    jne .next
    mov rdi, r12
    mov rsi, rbx
    mov rcx, r14
    repz cmpsb
    jne .next
    ; Found - return the original index
    mov rax, [post_sorted+r13*8]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.next:
    inc r13
    jmp .loop
.nf:
    mov rax, -1
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================
; Directory scanning and post index building
; ============================================================

; scan_posts: scan posts/ directory, build post index
; Uses bounded candidate maintenance: stores up to MAX_POSTS entries
; Keeps newest unique slugs
scan_posts:
    mov qword [post_count], 0

    mov eax, SYS_openat
    mov edi, AT_FDCWD
    lea rsi, [posts_dir]
    mov edx, O_RDONLY | O_DIRECTORY
    syscall
    test eax, eax
    js  .dir_missing

    mov r12d, eax       ; dir_fd
    mov [scan_dir_fd], eax

.read_loop:
    mov eax, SYS_getdents64
    mov edi, [scan_dir_fd]
    mov esi, dirent_buf
    mov edx, DIRENT_BUF_SIZE
    syscall
    test eax, eax
    js  .close_dir
    jz  .close_dir

    mov r13d, eax       ; bytes in buffer
    xor ebx, ebx        ; offset

.entry_loop:
    cmp ebx, r13d
    jae .read_loop

    movzx ecx, word [dirent_buf+rbx+DIRENT_D_RECLEN]
    mov r15d, ecx            ; save d_reclen for advancing
    test ecx, ecx
    jz  .read_loop


    cmp byte [dirent_buf+rbx+DIRENT_D_TYPE], DT_REG
    jne .next_entry
    ; print "Y" to stderr if parse successful

    lea rsi, [dirent_buf+rbx+DIRENT_D_NAME]
    mov rdi, rsi
    call strlen_cdecl
    mov rdx, rax
    push r13                ; save buffer_len before parse clobbers r13
    call parse_timestamped_filename
    pop r13                 ; restore buffer_len
    jne .next_entry

    ; Valid entry found - add to index immediately
    mov rcx, [post_count]
    cmp rcx, MAX_POSTS * 2
    jae .next_entry
    

    ; Copy filename
    mov r8, rcx              ; save index
    mov rdi, r8
    shl rdi, 6               ; rdi = r8 * 64 (FILENAME_MAX)
    lea rdi, [post_fnames+rdi]
    lea rsi, [dirent_buf+rbx+DIRENT_D_NAME]
    mov rcx, 63
.cp_fn:
    lodsb
    stosb
    test al, al
    jz  .cp_fn_done
    loop .cp_fn
.cp_fn_done:
    test rcx, rcx
    jz  .cp_fn_z
    mov al, 0
    rep stosb
.cp_fn_z:
    ; Store timestamp
    movzx eax, word [ts_year]
    mov [post_ts_year+r8*2], ax
    mov al, [ts_month]
    mov [post_ts_month+r8], al
    mov al, [ts_day]
    mov [post_ts_day+r8], al
    mov al, [ts_hour]
    mov [post_ts_hour+r8], al
    mov al, [ts_min]
    mov [post_ts_min+r8], al
    mov al, [ts_sec]
    mov [post_ts_sec+r8], al
    mov al, [ts_has_time]
    mov [post_has_time+r8], al
    mov rdi, r8
    shl rdi, 8               ; rdi = r8 * 256 (TITLE_MAX_LEN)
    mov byte [post_titles+rdi], 0
    inc qword [post_count]

.next_entry:
    add ebx, r15d
    jmp .entry_loop

.close_dir:
    mov eax, SYS_close
    mov edi, [scan_dir_fd]
    syscall
    call build_index
    ret

.dir_missing:
    mov dword [post_count], 0
    ret

; build_index: sort + dedup + read titles
build_index:
    mov rcx, [post_count]
    test rcx, rcx
    jz  .done

    ; Init sorted array with indices 0..count-1
    xor eax, eax
.init:
    mov [post_sorted+rax*8], rax
    inc rax
    cmp rax, rcx
    jb  .init

    ; Insertion sort (newest first)
    mov r8, 1
.outer:
    cmp r8, rcx
    jae .sorted
    mov r9, [post_sorted+r8*8]   ; key
    mov r10, r8
.inner:
    cmp r10, 0
    jbe .ins
    mov r11, [post_sorted+(r10-1)*8]
    mov rdi, r9
    mov rsi, r11
    push r8
    push r9
    push r10
    push rcx
    call ts_cmp_newer
    pop rcx
    pop r10
    pop r9
    pop r8
    jne .ins
    mov rax, [post_sorted+(r10-1)*8]
    mov [post_sorted+r10*8], rax
    dec r10
    jmp .inner
.ins:
    mov [post_sorted+r10*8], r9
    inc r8
    jmp .outer

.sorted:
    ; Dedup: keep first (newest) per slug, track unique
    xor r8d, r8d       ; write pos
    xor r9d, r9d       ; read pos
    xor r10d, r10d     ; unique count
.dedup:
    cmp r9, rcx
    jae .dedup_done
    mov r11, [post_sorted+r9*8]
    ; Check if slug matches any previously kept
    xor r12d, r12d
.check_dup:
    cmp r12, r10
    jae .kept
    mov r13, [post_sorted+r12*8]
    ; Compare filenames
    mov rdi, r11
    shl rdi, 6
    mov rsi, r13
    shl rsi, 6
    lea rdi, [post_fnames+rdi]
    lea rsi, [post_fnames+rsi]
    call strcmp_simple
    je  .dup_skip
    inc r12
    jmp .check_dup
.kept:
    mov rax, [post_sorted+r9*8]
    mov [post_sorted+r8*8], rax
    inc r8
    inc r10
    inc r9
    jmp .dedup
.dup_skip:
    inc r9
    jmp .dedup

.dedup_done:
    cmp r10, MAX_POSTS
    jbe .keep
    mov r10, MAX_POSTS
.keep:
    mov [post_count], r10

    ; Read frontmatter titles
    call read_all_titles
.done:
    ret

; ============================================================
; Frontmatter parsing
; ============================================================

; parse_frontmatter_title: rdi=buf, rsi=size → rax=title_ptr, rdx=title_len (0=none)
; title_ptr is within the mmap buffer
parse_frontmatter_title:
    cmp rsi, 4
    jb  .none
    cmp dword [rdi], 0x0A2D2D2D     ; "---\n"
    jne .none

    ; Find closing delimiter
    mov rcx, 4
.find_close:
    cmp rcx, rsi
    jae .none
    cmp byte [rdi+rcx], 0x0A
    jne .nxt
    lea rax, [rdi+rcx+1]
    cmp dword [rax], 0x0A2D2D2D     ; "---\n"
    je  .found_close
    cmp word [rax], 0x2D2D          ; "--" part of "---\r\n" check
    jne .nxt
    cmp byte [rax+2], 0x2D
    jne .nxt
    cmp byte [rax+3], 0x0D
    jne .nxt
    cmp byte [rax+4], 0x0A
    jne .nxt
    ; Found "\n---\r\n"
    add rcx, 5         ; skip past \n---\r\n
    jmp .found_close
.nxt:
    inc rcx
    jmp .find_close

.found_close:
    ; Frontmatter is from offset 4 to rcx-1 (rcx = position of delimiter '\n')
    mov r8, 4                ; start offset (skip "---\n")
    mov r9, rcx              ; end offset (position of '\n' before closing "---\n")
    sub r9, r8               ; frontmatter length
    add r8, rdi              ; make r8 absolute address again

    ; Search for "title: ..."
    xor eax, eax
.search:
    cmp rax, r9
    jae .none
    cmp byte [r8+rax], 't'
    jne .next_s
    cmp byte [r8+rax+1], 'i'
    jne .next_s
    cmp byte [r8+rax+2], 't'
    jne .next_s
    cmp byte [r8+rax+3], 'l'
    jne .next_s
    cmp byte [r8+rax+4], 'e'
    jne .next_s
    cmp byte [r8+rax+5], ':'
    jne .next_s
    cmp byte [r8+rax+6], ' '
    jne .next_s

    lea rax, [r8+rax+7]
    ; Find end of line
    mov rcx, rax
    sub rcx, r8
.find_eol:
    cmp rcx, r9
    jae .got_title
    cmp byte [r8+rcx], 0x0A
    je  .got_title
    inc rcx
    jmp .find_eol
.got_title:
    mov rdx, rcx
    add rdx, r8
    sub rdx, rax
    ret
.next_s:
    inc rax
    jmp .search

.none:
    xor eax, eax
    xor edx, edx
    ret

; truncate_title_utf8: truncate at rdx to valid UTF-8 boundary
; rdi=buf, rdx=max_len → returns truncated len in rdx
truncate_title_utf8:
    cmp byte [rdi+rdx-1], 0x80
    jb  .done
    cmp byte [rdi+rdx-1], 0xBF
    ja  .done
    dec rdx
    jnz truncate_title_utf8
.done:
    ret

; read_all_titles: read frontmatter for all retained posts
read_all_titles:
    xor r12d, r12d
.loop:
    cmp r12, [post_count]
    jae .done
    mov r13, [post_sorted+r12*8]

    ; Build path: "posts/" + filename
    mov rdi, path_buf
    lea rsi, [posts_prefix]
    mov ecx, 6
    rep movsb
    ; rdi now points to path_buf + 6
    mov rsi, r13
    shl rsi, 6
    lea rsi, [post_fnames+rsi]
    ; Save path_buf end pointer before strlen clobbers registers
    mov r8, rdi
    ; Get filename length via strlen
    mov rdi, rsi
    call strlen_cdecl
    mov rcx, rax
    ; Reload filename pointer and path_buf pointer
    mov rsi, r13
    shl rsi, 6
    lea rsi, [post_fnames+rsi]
    mov rdi, r8
    rep movsb
    mov byte [rdi], 0

    ; Open file
    mov eax, SYS_openat
    mov edi, AT_FDCWD
    mov esi, path_buf
    mov edx, O_RDONLY
    syscall
    test eax, eax
    js  .next

    mov r14d, eax

    ; fstat
    mov eax, SYS_fstat
    mov edi, r14d
    mov esi, stat_buf
    syscall
    test eax, eax
    js  .close_and_next

    mov r15, [stat_buf+STAT_ST_SIZE]
    cmp r15, MAX_POST_BYTES
    ja  .close_and_next
    test r15, r15
    jz  .empty_file

    ; mmap
    mov eax, SYS_mmap
    xor edi, edi
    mov rsi, r15
    mov edx, PROT_READ | PROT_WRITE
    mov r10d, MAP_PRIVATE
    mov r8d, r14d
    xor r9d, r9d
    syscall
    cmp rax, -1
    je  .close_and_next

    mov rbx, rax

    ; Parse frontmatter
    mov rdi, rbx
    mov rsi, r15
    call parse_frontmatter_title
    mov r8, rax       ; title ptr
    mov r9, rdx       ; title len

    ; Store title
    mov rdi, r13
    shl rdi, 8
    lea rdi, [post_titles+rdi]
    cmp r9, TITLE_MAX_LEN-4   ; leave room for "..."
    jb  .copy_title
    mov r9, TITLE_MAX_LEN-4
    push rdi
    call truncate_title_utf8
    pop rdi
.copy_title:
    mov rsi, r8
    mov rcx, r9
    test rcx, rcx
    jz  .no_title
    rep movsb
    cmp r9, TITLE_MAX_LEN-4
    ja  .add_dots
    mov byte [rdi], 0
    jmp .unmap
.add_dots:
    mov byte [rdi], '.'
    mov byte [rdi+1], '.'
    mov byte [rdi+2], '.'
    mov byte [rdi+3], 0
    jmp .unmap
.no_title:
    mov byte [rdi], 0

.unmap:
    mov eax, SYS_munmap
    mov rdi, rbx
    mov rsi, r15
    syscall

.close_and_next:
    mov eax, SYS_close
    mov edi, r14d
    syscall
    jmp .next

.empty_file:
    mov rdi, r13
    shl rdi, 8
    mov byte [post_titles+rdi], 0
    mov eax, SYS_close
    mov edi, r14d
    syscall
.next:
    inc r12
    jmp .loop
.done:
    ret

; ============================================================
; Display date formatting
; ============================================================

; format_display_date: rdi=post index → rsi=buf ptr (tmp_buf), rdx=len
format_display_date:
    push rbx
    push r12
    mov rbx, rdi
    mov rdi, tmp_buf
    mov r12, rdi

    movzx eax, word [post_ts_year+rbx*2]
    push rbx
    mov edx, 4
    call uint_to_str
    pop rbx
    mov rsi, rax
    movsd
    mov byte [rdi], '-'
    inc rdi

    movzx eax, byte [post_ts_month+rbx]
    push rbx
    mov edx, 2
    call uint_to_str
    pop rbx
    mov rsi, rax
    movsw
    mov byte [rdi], '-'
    inc rdi

    movzx eax, byte [post_ts_day+rbx]
    push rbx
    mov edx, 2
    call uint_to_str
    pop rbx
    mov rsi, rax
    movsw

    cmp byte [post_has_time+rbx], 0
    je  .done

    mov byte [rdi], ' '
    inc rdi

    movzx eax, byte [post_ts_hour+rbx]
    push rbx
    mov edx, 2
    call uint_to_str
    pop rbx
    mov rsi, rax
    movsw
    mov byte [rdi], ':'
    inc rdi

    movzx eax, byte [post_ts_min+rbx]
    push rbx
    mov edx, 2
    call uint_to_str
    pop rbx
    mov rsi, rax
    movsw
    mov byte [rdi], ':'
    inc rdi

    movzx eax, byte [post_ts_sec+rbx]
    push rbx
    mov edx, 2
    call uint_to_str
    pop rbx
    mov rsi, rax
    movsw

.done:
    mov rsi, r12
    mov rdx, rdi
    sub rdx, r12
    pop r12
    pop rbx
    ret

; uint_to_str: rax=uint, rdi=dst, edx=min_digits → rax=ptr to start of digits
uint_to_str:
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rdx
    add rdi, rdx
    mov byte [rdi], 0
    dec rdi
    mov ecx, 10
.loop:
    xor edx, edx
    div ecx
    add dl, '0'
    mov [rdi], dl
    dec rdi
    dec r12
    test eax, eax
    jnz .loop
.pad:
    cmp r12, 0
    jle .ret
    mov byte [rdi], '0'
    dec rdi
    dec r12
    jmp .pad
.ret:
    inc rdi
    mov rax, rdi
    pop r12
    pop rbx
    ret

; ============================================================
; Safe URL check
; ============================================================

; safe_url: rsi=url, rdx=len → ZF=1 if safe (http/https/mailto/relative)
safe_url:
    test rdx, rdx
    jz  .yes
    xor eax, eax
.fcolon:
    cmp rax, rdx
    je  .yes       ; no colon → relative
    cmp byte [rsi+rax], ':'
    je  .fnd
    inc rax
    jmp .fcolon
.fnd:
    test rax, rax
    jz  .no        ; colon at pos 0 → unsafe
    cmp byte [rsi+rax-1], ' '
    je  .no
    mov rcx, rax
    cmp rcx, 4
    jne .chk5
    mov r8d, [rsi]
    or  r8d, 0x20202020
    cmp r8d, 'http'
    je  .yes
.chk5:
    cmp rcx, 5
    jne .chk6
    mov r8d, [rsi]
    or  r8d, 0x20202020
    cmp r8d, 'http'
    jne .no
    cmp byte [rsi+4], 's'
    je  .yes
    or  byte [rsi+4], 0x20
    cmp byte [rsi+4], 's'
    je  .yes
    jmp .no
.chk6:
    cmp rcx, 6
    jne .no
    mov r8d, [rsi]
    or  r8d, 0x20202020
    cmp r8d, 'mail'
    jne .no
    mov r8w, [rsi+4]
    or  r8w, 0x2020
    cmp r8w, 'to'
    jne .no
.yes:
    cmp eax, eax
    ret
.no:
    mov eax, 1
    cmp eax, 0
    ret

; ============================================================
; Markdown inline renderer
; ============================================================

; render_inline: rsi=text, rdx=len → writes HTML to sink
render_inline:
    push r12
    push r13
    push r14
    push r15
    mov r12, rsi
    mov r13, rdx
    cmp r13, 0x40000
    jb  .ok
    jmp .done
.ok:
    xor r14d, r14d         ; position
.char_loop:
    cmp r14, r13
    jb  .do_char
    jmp .done
.do_char:

    mov al, [r12+r14]

    ; Backslash escape
    cmp al, '\'
    jne .chk_lt
    inc r14
    cmp r14, r13
    jae .done
    mov al, [r12+r14]
    call html_escape_byte
    inc r14
    jmp .char_loop

.chk_lt:
    cmp al, '<'
    je  .esc_lt
    cmp al, '>'
    je  .esc_gt
    cmp al, '&'
    je  .esc_amp
    cmp al, '"'
    je  .esc_quot

    ; Code span
    cmp al, '`'
    jne .chk_bang

    ; Count backticks
    mov r15, r14
.cnt_bt:
    inc r14
    lea rax, [r14+1]
    cmp rax, r13
    jae .bt_fallback
    cmp byte [r12+r14], '`'
    je  .cnt_bt
    mov rax, r14
    sub rax, r15            ; backtick count
    mov rbx, rax
    ; Find matching close
    mov rcx, r14
.find_close:
    cmp rcx, r13
    jae .bt_fallback
    cmp byte [r12+rcx], '`'
    jne .next_close
    ; Count backticks at this position
    mov r8, rcx
.cnt_close:
    inc r8
    cmp r8, r13
    jae .chk_close_cnt
    cmp byte [r12+r8], '`'
    je  .cnt_close
.chk_close_cnt:
    mov rdx, r8
    sub rdx, rcx
    cmp rdx, rbx
    jb  .next_close
    ; Found matching close
    push rcx
    WRITE_STR code_tag, 6
    pop rcx
    ; Render code span content with HTML escaping
    mov r9, rcx
    sub r9, r14             ; skip to close position
    push rbx
    push rcx
    mov rsi, r12
    add rsi, r14
    mov rdx, r9
    call html_escape_str
    pop rcx
    pop rbx
    push rcx
    WRITE_STR code_end, 7
    pop rcx
    mov r14, rcx
    add r14, rbx
    jmp .char_loop
.next_close:
    inc rcx
    jmp .find_close
.bt_fallback:
    mov al, '`'
    call write_byte
    inc r14
    jmp .char_loop

.chk_bang:
    cmp al, '!'
    jne .chk_bracket
    lea rax, [r14+1]
    cmp rax, r13
    jae .lit
    cmp byte [r12+r14+1], '['
    jne .lit
    ; Image: ![alt](url)
    add r14, 2
    ; Find ]
    mov rcx, r14
.find_rb:
    cmp rcx, r13
    jae .lit_img
    cmp byte [r12+rcx], ']'
    je  .fnd_rb
    inc rcx
    jmp .find_rb
.fnd_rb:
    lea rax, [rcx+1]
    cmp rax, r13
    jae .lit_img
    cmp byte [r12+rcx+1], '('
    jne .lit_img
    ; Find )
    mov r8, rcx
    add r8, 2
.find_rp:
    cmp r8, r13
    jae .lit_img
    cmp byte [r12+r8], ')'
    je  .fnd_rp
    inc r8
    jmp .find_rp
.fnd_rp:
    ; alt = [r12+r14 .. r12+rcx]
    ; url = [r12+rcx+2 .. r12+r8]
    lea rdi, [r12+rcx+2]
    mov r9, r8
    sub r9, rcx
    sub r9, 2
    push r14
    push rcx
    push r8
    mov rsi, rdi
    mov rdx, r9
    call safe_url
    pop r8
    pop rcx
    pop r14
    je  .img_safe_url
    ; Blocked: write #
    WRITE_STR img_bad, 7
    mov r14, r8
    inc r14
    jmp .char_loop
.img_safe_url:
    push rcx
    WRITE_STR img_tag1, 10
    pop rcx
    ; URL
    lea rsi, [r12+rcx+2]
    lea rdx, [r12+r8]
    sub rdx, rsi
    call html_escape_str
    push rcx
    WRITE_STR img_tag2, 7
    pop rcx
    ; Alt
    mov r9, rcx
    sub r9, r14
    lea rsi, [r12+r14]
    mov rdx, r9
    call html_escape_str
    WRITE_STR img_tag3, 2
    mov r14, r8
    inc r14
    jmp .char_loop
.lit_img:
    dec r14           ; backtrack
    jmp .lit

.chk_bracket:
    cmp al, '['
    jne .chk_em

    ; Link: [text](url)
    inc r14
    mov rcx, r14
.find_rb2:
    cmp rcx, r13
    jae .lit_link
    cmp byte [r12+rcx], ']'
    je  .fnd_rb2
    inc rcx
    jmp .find_rb2
.fnd_rb2:
    lea rax, [rcx+1]
    cmp rax, r13
    jae .lit_link
    cmp byte [r12+rcx+1], '('
    jne .lit_link
    mov r8, rcx
    add r8, 2
.find_rp2:
    cmp r8, r13
    jae .lit_link
    cmp byte [r12+r8], ')'
    je  .fnd_rp2
    inc r8
    jmp .find_rp2
.fnd_rp2:
    lea rdi, [r12+rcx+2]
    mov r9, r8
    sub r9, rcx
    sub r9, 2
    push r14
    push rcx
    push r8
    mov rsi, rdi
    mov rdx, r9
    call safe_url
    pop r8
    pop rcx
    pop r14
    je  .link_safe
    WRITE_STR link_bad, 11
    mov r14, r8
    inc r14
    jmp .char_loop
.link_safe:
    push rcx
    WRITE_STR link_tag1, 9
    pop rcx
    lea rsi, [r12+rcx+2]
    lea rdx, [r12+r8]
    sub rdx, rsi
    call html_escape_str
    push rcx
    WRITE_STR link_tag2, 2
    pop rcx
    ; Link text (inline rendered)
    mov r9, rcx
    sub r9, r14
    lea rsi, [r12+r14]
    mov rdx, r9
    push r13
    call render_inline   ; recursive
    pop r13
    WRITE_STR link_end, 4
    mov r14, r8
    inc r14
    jmp .char_loop
.lit_link:
    dec r14
    jmp .lit

.chk_em:
    cmp al, '*'
    je  .is_em
    cmp al, '_'
    je  .is_em
    jmp .lit

.is_em:
    mov r15b, al      ; delimiter char
    ; Count run length (max 2)
    mov r9, r14
.cnt_run:
    inc r9
    cmp r9, r13
    jae .chk_len
    cmp byte [r12+r9], r15b
    jne .chk_len
    inc r9
    cmp r9, r13
    jae .chk_len
    cmp byte [r12+r9], r15b
    jne .chk_len
    mov r9, 2
    jmp .em_do
.chk_len:
    mov r9, r9
    sub r9, r14
    cmp r9, 2
    ja  .em_do2
.em_do:
    ; check if r9 > 2, cap at 2
    cmp r9, 2
    jbe .em_ok
.em_do2:
    mov r9, 2
.em_ok:
    ; can_open check
    cmp r14, 0
    je  .can_open
    mov al, [r12+r14-1]
    cmp al, ' '
    je  .can_open
    cmp al, 0x09
    je  .can_open
    cmp al, 0x0A
    je  .can_open
    cmp al, '('
    je  .can_open
    cmp al, '['
    je  .can_open
    cmp al, '{'
    je  .can_open
    ; Not at word boundary → literal
    push r9
    movzx eax, r15b
    push rax
    mov al, r15b
    call write_byte
    pop rax
    pop r9
    dec r9
    jnz .em_ok     ; write remaining bytes as literals if multiple
    inc r14
    jmp .char_loop

.can_open:
    ; Find matching close
    push r14
    push r9
    mov rcx, r14
    add rcx, r9
.find_em_close:
    cmp rcx, r13
    jae .no_close
    mov al, [r12+rcx]
    cmp al, r15b
    jne .next_emc
    mov r8, rcx
.em_cnt_close:
    inc r8
    cmp r8, r13
    jae .em_cnt_close_done
    cmp byte [r12+r8], r15b
    je  .em_cnt_close
.em_cnt_close_done:
    mov r10, r8
    sub r10, rcx
    cmp r10, r9
    jb  .next_emc
    ; can_close check: delimiter preceded by non-space
    cmp rcx, 0
    je  .em_matched
    cmp byte [r12+rcx-1], ' '
    je  .next_emc
.em_matched:
    ; Found match
    pop r9
    add rsp, 8
    push rcx
    ; Write tag
    cmp r9, 2
    jne .em_tag
    WRITE_STR strong_tag, 8
    jmp .em_body
.em_tag:
    WRITE_STR em_tag, 4
.em_body:
    pop rcx
    ; Render content between delimiters
    mov rsi, r12
    add rsi, r14
    add rsi, r9
    mov rdx, rcx
    sub rdx, r14
    sub rdx, r9
    push rcx
    push r9
    push r13
    call render_inline
    pop r13
    pop r9
    pop rcx
    ; Write close tag
    push rcx
    cmp r9, 2
    jne .em_close_tag
    WRITE_STR strong_end, 9
    jmp .em_done
.em_close_tag:
    WRITE_STR em_end, 5
.em_done:
    pop rcx
    mov r14, rcx
    add r14, r9
    jmp .char_loop
.next_emc:
    inc rcx
    jmp .find_em_close
.no_close:
    pop r9
    pop r14
    mov rbx, r9
.no_close_lit:
    push r9
    mov al, r15b
    call write_byte
    pop r9
    dec r9
    jnz .no_close_lit
    add r14, rbx
    jmp .char_loop

.lit:
    call write_byte
    inc r14
    jmp .char_loop

.esc_lt:
    WRITE_STR lt_ent, 4
    inc r14
    jmp .char_loop
.esc_gt:
    WRITE_STR gt_ent, 4
    inc r14
    jmp .char_loop
.esc_amp:
    WRITE_STR amp_ent, 5
    inc r14
    jmp .char_loop
.esc_quot:
    WRITE_STR quot_ent, 6
    inc r14
    jmp .char_loop

.done:
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; ============================================================
; Markdown block parser
; ============================================================

; normalize_code_spans: replace \n with space inside backtick spans (mutates buf)
; rdi=buf, rsi=size
normalize_code_spans:
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
    xor ecx, ecx
.loop:
    cmp rcx, r13
    jae .done
    cmp byte [r12+rcx], '`'
    jne .next
    mov r8, rcx
    inc r8
.cnt:
    cmp r8, r13
    jae .next
    cmp byte [r12+r8], '`'
    jne .chk_len2
    inc r8
    jmp .cnt
.chk_len2:
    mov r9, r8
    sub r9, rcx           ; backtick count
.find_close:
    cmp r8, r13
    jae .next
    cmp byte [r12+r8], '`'
    jne .fcnxt
    mov r10, r8
.cntc:
    inc r10
    cmp r10, r13
    jae .chk_c
    cmp byte [r12+r10], '`'
    je  .cntc
.chk_c:
    mov r11, r10
    sub r11, r8
    cmp r11, r9
    jb  .fcnxt
    ; Found matching close. Replace \n with space between cx+r9 and r8
    mov rdx, rcx
    add rdx, r9
.repl:
    cmp rdx, r8
    jae .skip_span
    cmp byte [r12+rdx], 0x0A
    jne .rnxt
    mov byte [r12+rdx], ' '
.rnxt:
    inc rdx
    jmp .repl
.skip_span:
    mov rcx, r8
    add rcx, r9
    jmp .loop
.fcnxt:
    inc r8
    jmp .find_close
.next:
    inc rcx
    jmp .loop
.done:
    pop r13
    pop r12
    ret

; parse_heading: rsi=line, rdx=len → ZF=1 if heading, outputs to sink
parse_heading:
    push r12
    push r13
    mov r12, rsi
    mov r13, rdx
    xor ecx, ecx
.cnt_hash:
    cmp ecx, r13d
    jae .no
    cmp byte [r12+rcx], '#'
    jne .chk_spc
    inc ecx
    cmp ecx, 7
    jb  .cnt_hash
    jmp .no
.chk_spc:
    test ecx, ecx
    jz  .no
    cmp byte [r12+rcx], ' '
    jne .no
    mov r8d, ecx
    inc ecx                 ; skip space
    cmp ecx, r13d
    jae .no

    ; r8d = heading level (hash count), ecx = position past space
    lea rsi, [r12+rcx]
    mov rdx, r13
    sub rdx, rcx
    ; Trim trailing # and spaces
    mov rcx, rdx
.trim:
    test rcx, rcx
    jz  .trim_done
    dec rcx
    cmp byte [rsi+rcx], '#'
    je  .trim
    cmp byte [rsi+rcx], ' '
    je  .trim
    cmp byte [rsi+rcx], 0x09
    je  .trim
    inc rcx
.trim_done:
    ; Write <hN>
    mov al, '<'
    call write_byte
    mov al, 'h'
    call write_byte
    mov al, r8b
    add al, '0'
    call write_byte
    mov al, '>'
    call write_byte

    ; Render content
    push r8
    push rcx
    push r13
    mov rdx, rcx
    call render_inline
    pop r13
    pop rcx
    pop r8

    ; Write </hN>\n
    mov al, '<'
    call write_byte
    mov al, '/'
    call write_byte
    mov al, 'h'
    call write_byte
    mov al, r8b
    add al, '0'
    call write_byte
    mov al, '>'
    call write_byte
    mov al, 0x0A
    call write_byte

    pop r13
    pop r12
    cmp eax, eax
    ret
.no:
    pop r13
    pop r12
    mov eax, 1
    cmp eax, 0
    ret

; parse_thematic_break: rsi=line, rdx=len → ZF=1 if hr
parse_thematic_break:
    cmp rdx, 3
    jb  .no
    mov al, [rsi]
    cmp al, '-'
    je  .check
    cmp al, '*'
    je  .check
    cmp al, '_'
    je  .check
    jmp .no
.check:
    mov cl, al
    mov r8, rdx
    xor eax, eax
.loop:
    cmp rax, r8
    je  .yes
    mov dl, [rsi+rax]
    cmp dl, cl
    je  .next
    cmp dl, ' '
    je  .next
    cmp dl, 0x09
    je  .next
    cmp dl, 0x0D
    je  .next
    jmp .no
.next:
    inc rax
    jmp .loop
.yes:
    WRITE_STR hr_str, 5
    cmp eax, eax
    ret
.no:
    mov eax, 1
    cmp eax, 0
    ret

; is_list_item: rsi=line, rdx=len → rax=0=no, 1=bullet, 2=ordered, rcx=content offset
is_list_item:
    test rdx, rdx
    jz  .no
    ; Bullet: "- " or "* "
    cmp byte [rsi], '-'
    je  .chk_bullet
    cmp byte [rsi], '*'
    jne .chk_ordered
.chk_bullet:
    cmp rdx, 2
    jb  .no
    cmp byte [rsi+1], ' '
    jne .no
    mov eax, 1
    mov ecx, 2
    ret
.chk_ordered:
    ; Ordered: digits then ". "
    xor ecx, ecx
.cnt_digits:
    cmp ecx, edx
    jae .no
    cmp byte [rsi+rcx], '0'
    jb  .chk_done
    cmp byte [rsi+rcx], '9'
    ja  .chk_done
    inc ecx
    jmp .cnt_digits
.chk_done:
    test ecx, ecx
    jz  .no
    cmp byte [rsi+rcx], '.'
    jne .no
    inc ecx
    cmp ecx, edx
    jae .no
    cmp byte [rsi+rcx], ' '
    jne .no
    inc ecx
    mov eax, 2
    ret
.no:
    xor eax, eax
    ret

; to_html: rdi=doc (mmap'd), rsi=size → renders markdown to sink
to_html:
    push r12
    push r13
    push r14
    push r15
    push rbx
    mov r12, rdi       ; doc ptr
    mov r13, rsi       ; doc size
    mov [to_html_size], r13

    ; Normalize code spans (mutate in place)
    call normalize_code_spans

    ; Line-by-line parsing
    xor r14d, r14d      ; current position in doc
    mov byte [in_list], 0
    mov byte [list_ordered], 0
    mov qword [list_count], 0
    mov qword [para_count], 0

.line_loop:
    mov r13, [to_html_size]
    lea rax, [r14+1]
    cmp rax, r13
    jae .flush_all

    ; Find end of line
    mov r15, r14
.find_eol:
    cmp r15, r13
    je  .got_line
    cmp byte [r12+r15], 0x0A
    je  .got_line
    inc r15
    jmp .find_eol
.got_line:
    mov rbx, r15
    sub rbx, r14            ; line length

    ; Trim trailing \r
    test rbx, rbx
    jz  .no_trim
    cmp byte [r12+r15-1], 0x0D
    jne .no_trim
    dec rbx
.no_trim:

    ; Is this a blank line?
    cmp rbx, 0
    jne .not_blank

    ; Blank line: flush list + paragraph
    call flush_list
    call flush_para
    jmp .next_line

.not_blank:
    ; Try heading
    lea rsi, [r12+r14]
    mov rdx, rbx
    call parse_heading
    je  .next_line

    ; Try thematic break
    lea rsi, [r12+r14]
    mov rdx, rbx
    call parse_thematic_break
    je  .next_line

    ; Try list item
    lea rsi, [r12+r14]
    mov rdx, rbx
    call is_list_item
    test eax, eax
    jz  .not_list

    cmp byte [in_list], 0
    jne .add_to_list
    mov byte [in_list], 1
    cmp eax, 2
    sete byte [list_ordered]
    ; Store first list item
    add r14, rcx
    mov rdx, rbx
    sub rdx, rcx
    lea rsi, [r12+r14]
    sub r14, rcx         ; restore r14 for line end calc
    jmp .add_list_item
.add_to_list:
    ; Append to existing list
    add r14, rcx
    mov rdx, rbx
    sub rdx, rcx
    lea rsi, [r12+r14]
    sub r14, rcx
    jmp .add_list_item

.not_list:
    ; If we were in a list, flush
    cmp byte [in_list], 0
    je  .add_para
    call flush_list

.add_para:
    ; Add to paragraph
    mov rcx, [para_count]
    cmp rcx, 128
    jae .next_line
    lea rax, [r12+r14]
    mov [para_lines+rcx*8], rax
    mov [para_lens+rcx*8], rbx
    inc qword [para_count]
    jmp .next_line

.add_list_item:
    mov rcx, [list_count]
    cmp rcx, 64
    jae .next_line
    mov [list_lines+rcx*8], rsi
    mov [list_lens+rcx*8], rdx
    inc qword [list_count]
    jmp .next_line

.next_line:
    mov r14, r15
    inc r14                ; skip newline
    jmp .line_loop

.flush_all:
    call flush_list
    call flush_para

    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret

flush_para:
    mov rcx, [para_count]
    test rcx, rcx
    jz  .done
    WRITE_STR p_tag, 3
    mov rcx, [para_count]
    xor ebx, ebx
.p_loop:
    cmp rbx, rcx
    jae .p_end
    cmp rbx, 0
    je  .p_first
    mov al, ' '
    call write_byte
.p_first:
    mov rsi, [para_lines+rbx*8]
    mov rdx, [para_lens+rbx*8]
    push rcx
    call render_inline
    pop rcx
    inc rbx
    jmp .p_loop
.p_end:
    WRITE_STR p_end, 5
    mov qword [para_count], 0
.done:
    ret

flush_list:
    cmp byte [in_list], 0
    je  .done
    mov rcx, [list_count]
    cmp byte [list_ordered], 0
    je  .ul

    WRITE_STR ol_tag, 5
    mov rcx, [list_count]
    jmp .items
.ul:
    WRITE_STR ul_tag, 5
    mov rcx, [list_count]
.items:
    xor ebx, ebx
.l_loop:
    cmp rbx, rcx
    jae .l_end
    push rcx
    WRITE_STR li_tag, 4
    mov rsi, [list_lines+rbx*8]
    mov rdx, [list_lens+rbx*8]
    call render_inline
    WRITE_STR li_end, 6
    pop rcx
    inc rbx
    jmp .l_loop
.l_end:
    cmp byte [list_ordered], 0
    je  .ul_end
    WRITE_STR ol_end, 6
    jmp .clear
.ul_end:
    WRITE_STR ul_end, 6
.clear:
    mov qword [list_count], 0
    mov byte [in_list], 0
.done:
    ret

; ============================================================
; Post page rendering
; ============================================================

; render_post_page: render a single post page (wrapper + markdown body)
; Expects post data in index at current_post_idx (set by caller)
; title_ptr, date_ptr, body_ptr, body_len should be set by caller
render_post_page:
    ; Write document shell start
    WRITE_STR doc1, doc1_len
    WRITE_STR title1, title1_len
    ; Title: "<post_title> — massless"
    mov rsi, [render_title]
    mov rdx, [render_title_len]
    call html_escape_str
    WRITE_STR title_sep, title_sep_len
    WRITE_STR site_title_str, site_title_str_len
    WRITE_STR title2, title2_len
    WRITE_STR doc2, doc2_len
    cmp byte [HOT_RELOAD_BYTE], 1
    jne .no_sse
    WRITE_STR sse_scr, sse_scr_len
.no_sse:
    WRITE_STR doc3, doc3_len
    WRITE_STR site_title_str, site_title_str_len
    WRITE_STR doc4, doc4_len

    ; Article start
    WRITE_STR article_tag, 9
    WRITE_STR h1_tag, 4
    mov rsi, [render_title]
    mov rdx, [render_title_len]
    call html_escape_str
    WRITE_STR h1_end, h1_end_len
    WRITE_STR time_tag, 6
    mov rsi, [render_date]
    mov rdx, [render_date_len]
    call html_escape_str
    WRITE_STR time_end, 7

    ; Render markdown body
    mov rdi, [render_body]
    mov rsi, [render_body_len]
    call to_html

    ; Footer
    WRITE_STR article_end, article_end_len
    WRITE_STR doc_end, doc_end_len
    ret

; ============================================================
; Homepage renderer (populated from real posts)
; ============================================================

render_homepage:
    WRITE_STR doc1, doc1_len
    WRITE_STR title1, title1_len
    WRITE_STR site_title_str, site_title_str_len
    WRITE_STR title2, title2_len
    WRITE_STR doc2, doc2_len
    cmp byte [HOT_RELOAD_BYTE], 1
    jne .no_sse
    WRITE_STR sse_scr, sse_scr_len
.no_sse:
    WRITE_STR doc3, doc3_len
    WRITE_STR site_title_str, site_title_str_len
    WRITE_STR doc4, doc4_len

    xor r12d, r12d
.list_loop:
    cmp r12, [post_count]
    jae .list_done
    mov r13, [post_sorted+r12*8]

    WRITE_STR art_time1, art_time1_len
    mov rdi, r13
    call format_display_date
    call write_str
    WRITE_STR art_time2, art_time2_len

    ; Get slug from filename
    push r12
    push r13
    mov rdi, r13
    shl rdi, 6
    lea rsi, [post_fnames+rdi]
    mov rdi, rsi
    call strlen_cdecl
    mov rdx, rax
    call parse_timestamped_filename
    jne .slug_fail
    ; r12=slug_ptr, r13=slug_len
    mov rsi, r12
    mov rdx, r13
    call html_escape_str
    pop r13
    pop r12
    jmp .write_title
.slug_fail:
    pop r13
    pop r12
    WRITE_STR art_time3, art_time3_len
    WRITE_STR art_end, art_end_len
    inc r12
    jmp .list_loop

.write_title:
    WRITE_STR art_time3, art_time3_len
    ; Write title (escaped)
    push r12
    mov rdi, r13
    shl rdi, 8
    lea rsi, [post_titles+rdi]
    mov rdi, rsi
    call strlen_cdecl
    mov rdx, rax
    call html_escape_str
    pop r12

    WRITE_STR art_end, art_end_len
    inc r12
    jmp .list_loop

.list_done:
    WRITE_STR doc_end, doc_end_len
    ret

; ============================================================
; Static file serving
; ============================================================

serve_public:
    push r12
    push r13
    mov r12, rsi
    mov r13, rdx

    mov rdi, path_buf
    lea rsi, [pub_prefix]
    mov ecx, 7
    rep movsb
    mov rsi, r12
    mov rcx, r13
    rep movsb
    mov byte [rdi], 0

    mov eax, SYS_openat
    mov edi, AT_FDCWD
    mov esi, path_buf
    mov edx, O_RDONLY
    syscall
    test eax, eax
    js  .nf

    mov r12d, eax

    mov eax, SYS_fstat
    mov edi, r12d
    mov esi, stat_buf
    syscall
    test eax, eax
    js  .close_nf

    mov rax, [stat_buf+STAT_ST_SIZE]
    cmp rax, MAX_PUBLIC_BYTES
    ja  .close_nf
    mov r13, rax

    lea rsi, [path_buf+7]
    mov rdi, rsi
    call strlen_cdecl
    mov rcx, rax
    lea rsi, [path_buf+7]
.fdot:
    test rcx, rcx
    jz  .def_mime
    dec rcx
    cmp byte [rsi+rcx], '.'
    je  .got_ext
    jmp .fdot
.got_ext:
    lea rsi, [rsi+rcx]
    cmp dword [rsi], '.css'
    jne .chk_js
    cmp byte [rsi+4], 0
    jne .chk_js
    lea rsi, [mime_css_str]
    jmp .whdr
.chk_js:
    cmp dword [rsi], '.js'
    jne .def_mime
    cmp byte [rsi+3], 0
    jne .def_mime
    lea rsi, [mime_js_str]
    jmp .whdr
.def_mime:
    lea rsi, [mime_def_str]

.whdr:
    call write_status_ok
    mov rdi, rsi
    call strlen_cdecl
    mov rdx, rax
    WRITE_STR ct_prefix, 14
    call write_str
    WRITE_STR crlf_str, 2
    mov rax, r13
    call write_cl_hdr
    call write_security
    call write_conn_close
    WRITE_STR crlf_str, 2
    call flush_send_buf

    cmp byte [output_mode], 1
    je  .skip_body
    mov eax, SYS_sendfile
    mov edi, [client_fd]
    mov esi, r12d
    xor edx, edx
    mov r10, r13
    syscall
.skip_body:
    mov eax, SYS_close
    mov edi, r12d
    syscall
    pop r13
    pop r12
    ret

.close_nf:
    mov eax, SYS_close
    mov edi, r12d
    syscall
.nf:
    pop r13
    pop r12
    WRITE_STR n404, n404_len
    ret

; ============================================================
; Safe path check
; ============================================================

; is_safe_rel_path: rsi=path, rdx=len → ZF=1 if safe
is_safe_rel_path:
    test rdx, rdx
    jz  .no
    cmp byte [rsi], '/'
    je  .no
    push r12
    push r13
    mov r12, rsi
    mov r13, rdx
    xor ecx, ecx
.clp:
    cmp rcx, r13
    je  .seg
    mov al, [r12+rcx]
    cmp al, '\'
    je  .no_pop
    cmp al, 0x20
    jb  .no_pop
    cmp al, 0x7f
    je  .no_pop
    inc rcx
    jmp .clp
.seg:
    xor ecx, ecx
    mov rsi, r12
.slp:
    cmp rcx, r13
    je  .lst
    cmp byte [r12+rcx], '/'
    jne .nxt
    mov rdi, rcx
    sub rdi, rsi
    cmp rdi, 0
    je  .no_pop
    cmp rdi, 1
    jne .chk2
    cmp byte [r12+rsi], '.'
    je  .no_pop
    jmp .nxt_seg
.chk2:
    cmp rdi, 2
    jne .nxt_seg
    cmp word [r12+rsi], '..'
    je  .no_pop
.nxt_seg:
    lea rsi, [r12+rcx+1]
.nxt:
    inc rcx
    jmp .slp
.lst:
    mov rdi, r13
    sub rdi, rsi
    cmp rdi, 0
    je  .no_pop
    cmp rdi, 1
    jne .chk2l
    cmp byte [r12+rsi], '.'
    je  .no_pop
    jmp .yes_pop
.chk2l:
    cmp rdi, 2
    jne .yes_pop
    cmp word [r12+rsi], '..'
    je  .no_pop
    jmp .yes_pop
.yes_pop:
    pop r13
    pop r12
    cmp eax, eax
    ret
.no_pop:
    pop r13
    pop r12
.no:
    mov eax, 1
    cmp eax, 0
    ret

; ============================================================
; SSE
; ============================================================

sse_add:
    mov rcx, [sse_count]
    cmp rcx, MAX_SSE_CLIENTS
    jae .full
    mov [sse_fds+rcx*4], edi
    inc qword [sse_count]
    ret
.full:
    mov eax, SYS_close
    syscall
    ret

; Remove SSE client at index r12, using swap-with-last-and-pop.
; Clobbers rax, rcx, rdi.
; Preserves r12 (index removed, caller should NOT increment index).
sse_remove:
    mov eax, [sse_fds+r12*4]
    dec qword [sse_count]
    mov rcx, [sse_count]
    cmp r12, rcx
    jae .done
    mov edi, [sse_fds+rcx*4]
    mov [sse_fds+r12*4], edi
.done:
    mov edi, eax
    mov eax, SYS_close
    syscall
    ret

; Send keepalives to all SSE clients. Remove dead clients.
sse_keepalives:
    mov rcx, [sse_count]
    test rcx, rcx
    jz  .done
    xor r12d, r12d
.kl:
    cmp r12, [sse_count]
    jae .done
    mov edi, [sse_fds+r12*4]
    mov eax, SYS_write
    lea rsi, [sse_ka]
    mov edx, 12
    syscall
    test eax, eax
    jns .kl_next
    call sse_remove
    jmp .kl
.kl_next:
    inc r12
    jmp .kl
.done:
    ret

; Send reload event to all SSE clients and close them.
sse_reload_all:
    mov rcx, [sse_count]
    test rcx, rcx
    jz  .done
    xor r12d, r12d
.rl:
    cmp r12, [sse_count]
    jae .clear
    mov edi, [sse_fds+r12*4]
    mov eax, SYS_write
    lea rsi, [sse_rld]
    mov edx, 14
    syscall
    mov eax, SYS_close
    mov edi, [sse_fds+r12*4]
    syscall
    inc r12
    jmp .rl
.clear:
    mov qword [sse_count], 0
.done:
    ret

; ============================================================
; Request handler
; ============================================================

read_request:
    mov eax, SYS_read
    mov edi, [client_fd]
    mov esi, recv_buf
    mov edx, RECV_BUF_SIZE
    syscall
    test eax, eax
    jle .fail

    ; 431 check: if read filled the buffer and no \r\n\r\n, headers too large
    cmp eax, HEADER_MAX_LEN
    jb  .hdr_ok
    ; Scan for \r\n\r\n
    mov rcx, rax
    sub rcx, 3
    xor edx, edx
.hdr_scan:
    cmp rdx, rcx
    jae .header_too_large
    cmp dword [recv_buf+rdx], 0x0A0D0A0D
    je  .hdr_ok
    inc rdx
    jmp .hdr_scan
.hdr_ok:

    cmp dword [recv_buf], 'GET '
    je  .is_get
    cmp dword [recv_buf], 'HEAD'
    jne .bad_method
    cmp byte [recv_buf+4], ' '
    jne .bad_method
    mov r12d, 1
    lea rsi, [recv_buf+5]
    jmp .parse_path
.is_get:
    mov r12d, 0
    lea rsi, [recv_buf+4]
.parse_path:
    mov r13, rsi
.find_end:
    mov al, [rsi]
    cmp al, ' '
    je  .path_check
    cmp al, 0x0D
    je  .path_check
    cmp al, '?'
    je  .path_check
    cmp al, '#'
    je  .path_check
    cmp al, 0
    je  .path_check
    inc rsi
    jmp .find_end
.path_check:
    mov rax, rsi
    sub rax, r13
    cmp rax, PATH_MAX_LEN - 1
    jbe .path_end
    mov byte [rsi], 0
    jmp .path_too_long
.path_end:
    mov byte [rsi], 0
    cmp eax, eax
    ret
.path_too_long:
    mov byte [output_mode], 0
    call send_414
    jmp .fail
.header_too_large:
    mov byte [output_mode], 0
    call send_431
    jmp .fail
.bad_method:
    mov byte [output_mode], 0
    call send_405
.fail:
    mov eax, SYS_close
    mov edi, [client_fd]
    syscall
    mov eax, 1
    cmp eax, 0
    ret

match_route:
    cmp byte [rsi], '/'
    jne .nf
    cmp byte [rsi+1], 0
    je  .home
    cmp dword [rsi], '/pos'
    jne .chk_event
    cmp word [rsi+4], 'ts'
    jne .chk_event
    cmp byte [rsi+6], 0
    je  .posts_list
    cmp byte [rsi+6], '/'
    jne .chk_event
    lea r12, [rsi+7]
    mov rdi, r12
    call strlen_cdecl
    mov r13, rax
    mov eax, 2
    ret
.chk_event:
    cmp dword [rsi], '/eve'
    jne .chk_public
    cmp word [rsi+4], 'nt'
    jne .chk_public
    cmp byte [rsi+6], 's'
    jne .chk_public
    cmp byte [rsi+7], 0
    je  .events
.chk_public:
    cmp dword [rsi], '/pub'
    jne .nf
    cmp dword [rsi+4], 'lic/'
    jne .nf
    lea r12, [rsi+8]
    mov rdi, r12
    call strlen_cdecl
    mov r13, rax
    mov eax, 3
    ret
.home:
    xor eax, eax
    ret
.posts_list:
    mov eax, 1
    ret
.events:
    mov eax, 4
    ret
.nf:
    mov eax, 5
    ret

; ============================================================
; Connection handler
; ============================================================

handle_connection:
    mov [client_fd], rdi
    mov eax, SYS_setsockopt
    mov esi, SOL_SOCKET
    mov edx, SO_RCVTIMEO
    lea r10, [rcv_timeout_data]
    mov r8d, 16
    syscall

    call read_request
    jne .done

    mov r15, r12
    mov rsi, r13
    call match_route
    mov r14, rax

    cmp r14, 0
    je  .home
    cmp r14, 1
    je  .redirect
    cmp r14, 2
    je  .post
    cmp r14, 3
    je  .public
    cmp r14, 4
    je  .events
    jmp .not_found

.home:
    cmp r15, 1
    jne .home_get
    mov byte [output_mode], 1
    mov qword [byte_count], 0
    call render_homepage
    mov rbx, [byte_count]
    mov byte [output_mode], 0
    mov rax, rbx
    call write_html_headers
    call flush_send_buf
    jmp .close

.home_get:
    mov byte [output_mode], 1
    mov qword [byte_count], 0
    call render_homepage
    mov rbx, [byte_count]
    mov byte [output_mode], 0
    mov rax, rbx
    call write_html_headers
    call render_homepage
    call flush_send_buf
    jmp .close

.redirect:
    mov byte [output_mode], 0
    call send_303
    jmp .close

.post:
    mov rsi, r12
    mov rdx, r13
    call is_safe_slug
    jne .not_found

    ; Find post by slug
    mov rsi, r12
    mov rdx, r13
    call find_post_by_slug
    cmp rax, -1
    je  .not_found

    mov r14, rax     ; post index     ; post index

    ; Save HTTP method before it gets clobbered
    mov r8, r15      ; r8 = HTTP method (0=GET, 1=HEAD)

    ; Build path, mmap file
    mov rdi, path_buf
    lea rsi, [posts_prefix]
    mov ecx, 6
    rep movsb
    mov rsi, r14
    shl rsi, 6
    lea rsi, [post_fnames+rsi]
    mov rdi, rsi
    call strlen_cdecl
    mov rcx, rax
    mov rsi, r14
    shl rsi, 6
    lea rsi, [post_fnames+rsi]
    mov qword [r8_save], r8
    mov rdi, path_buf
    add rdi, 6
    rep movsb
    mov byte [rdi], 0
    mov r8, qword [r8_save]

    mov eax, SYS_openat
    mov edi, AT_FDCWD
    mov esi, path_buf
    mov edx, O_RDONLY
    syscall
    test eax, eax
    js  .not_found

    mov ebx, eax     ; file_fd

    mov eax, SYS_fstat
    mov edi, ebx
    mov esi, stat_buf
    syscall
    test eax, eax
    js  .close_nf

    mov r15, [stat_buf+STAT_ST_SIZE]
    cmp r15, MAX_POST_BYTES
    ja  .close_nf

    test r15, r15
    jz  .empty_post

    mov eax, SYS_mmap
    xor edi, edi
    mov rsi, r15
    mov edx, PROT_READ | PROT_WRITE
    mov r10d, MAP_PRIVATE
    mov r8d, ebx
    xor r9d, r9d
    syscall
    cmp rax, -1
    je  .close_nf

    mov r12, rax      ; mmap'd buffer

    ; Parse frontmatter
    mov rdi, r12
    mov rsi, r15
    call parse_frontmatter_title
    mov [render_title], rax
    mov [render_title_len], rdx

    ; Build display date
    mov rdi, r14
    call format_display_date
    mov [render_date], rsi
    mov [render_date_len], rdx

    ; Body = content after frontmatter
    mov rdi, r12
    mov rsi, r15
    call find_body_start
    mov [render_body], rax
    mov [render_body_len], rdx

    ; Two-pass render — use r8 for method check
    cmp r8, 1          ; HEAD?
    jne .post_get

    ; HEAD
    mov byte [output_mode], 1
    mov qword [byte_count], 0
    call render_post_page
    mov rbx, [byte_count]
    mov byte [output_mode], 0
    mov rax, rbx
    call write_html_headers
    call flush_send_buf
    jmp .post_done

.post_get:
    mov byte [output_mode], 1
    mov qword [byte_count], 0
    call render_post_page
    mov rbx, [byte_count]
    mov byte [output_mode], 0
    mov rax, rbx
    call write_html_headers
    call render_post_page
    call flush_send_buf

.post_done:
    mov eax, SYS_munmap
    mov rdi, r12
    mov rsi, r15
    syscall
    mov eax, SYS_close
    mov edi, ebx
    syscall
    jmp .close

.empty_post:
    lea rax, [empty_str]
    mov [render_title], rax
    mov qword [render_title_len], 0
    lea rax, [empty_str]
    mov [render_body], rax
    mov qword [render_body_len], 0
    mov rdi, r14
    call format_display_date
    mov [render_date], rsi
    mov [render_date_len], rdx

    cmp r8, 1           ; HEAD?
    jne .ep_get
    mov byte [output_mode], 1
    mov qword [byte_count], 0
    call render_post_page
    mov rbx, [byte_count]
    mov byte [output_mode], 0
    mov rax, rbx
    call write_html_headers
    call flush_send_buf
    jmp .ep_close
.ep_get:
    mov byte [output_mode], 1
    mov qword [byte_count], 0
    call render_post_page
    mov rbx, [byte_count]
    mov byte [output_mode], 0
    mov rax, rbx
    call write_html_headers
    call render_post_page
    call flush_send_buf
.ep_close:
    mov eax, SYS_close
    mov edi, ebx
    syscall
    jmp .close

.close_nf:
    mov eax, SYS_close
    mov edi, ebx
    syscall
    jmp .not_found

.public:
    mov byte [output_mode], 0
    mov rsi, r12
    mov rdx, r13
    call is_safe_rel_path
    jne .not_found
    call serve_public
    jmp .close

.events:
    cmp byte [HOT_RELOAD_BYTE], 1
    jne .not_found
    mov rax, [sse_count]
    cmp rax, MAX_SSE_CLIENTS
    jae .events_full
    mov byte [output_mode], 0
    WRITE_STR sse_hdrs, sse_hdrs_len
    WRITE_STR sse_conn, sse_conn_len
    call flush_send_buf
    mov edi, [client_fd]
    call sse_add
    mov qword [client_fd], -1
    jmp .done
.events_full:
    mov byte [output_mode], 0
    call send_503
    jmp .close

.not_found:
    cmp r15, 1
    jne .nf_get
    mov byte [output_mode], 1
    mov qword [byte_count], 0
    WRITE_STR n404, n404_len
    mov rbx, [byte_count]
    mov byte [output_mode], 0
    WRITE_STR http_404, http_404_len
    call write_ct_html
    mov rax, rbx
    call write_cl_hdr
    call write_security
    call write_csp
    call write_conn_close
    WRITE_STR crlf_str, 2
    WRITE_STR n404, n404_len
    call flush_send_buf
    jmp .close
.nf_get:
    mov rax, n404_len
    call write_html_404_headers
    WRITE_STR n404, n404_len
    call flush_send_buf
    jmp .close

.close:
    cmp qword [client_fd], -1
    je  .done
    mov eax, SYS_close
    mov edi, [client_fd]
    syscall
.done:
    ret

; find_body_start: rdi=buf, rsi=size → rax=body_ptr, rdx=body_len
find_body_start:
    cmp rsi, 4
    jb  .full
    cmp dword [rdi], 0x0A2D2D2D
    jne .full
    mov rcx, 4
.srch:
    cmp rcx, rsi
    jae .full
    cmp byte [rdi+rcx], 0x0A
    jne .nxt2
    lea rax, [rdi+rcx+1]
    cmp dword [rax], 0x0A2D2D2D
    je  .fnd
    cmp word [rax], 0x2D2D
    jne .nxt2
    cmp byte [rax+2], 0x2D
    jne .nxt2
    cmp byte [rax+3], 0x0D
    jne .nxt2
    cmp byte [rax+4], 0x0A
    jne .nxt2
    add rcx, 5
    jmp .fnd
.nxt2:
    inc rcx
    jmp .srch
.fnd:
    add rcx, 5         ; past \n---\n
    cmp rcx, rsi
    jae .empty_end
    lea rax, [rdi+rcx]
    mov rdx, rsi
    sub rdx, rcx
    ret
.empty_end:
    lea rax, [empty_str]
    xor edx, edx
    ret
.full:
    mov rax, rdi
    mov rdx, rsi
    ret

; ============================================================
; Main
; ============================================================

_start:
    mov byte [HOT_RELOAD_BYTE], HOT_RELOAD

    sub rsp, 32
    mov qword [rsp], 1
    mov qword [rsp+8], 0x04000000
    lea rax, [rel .sigreturn]
    mov qword [rsp+16], rax
    mov eax, SYS_rt_sigaction
    mov edi, 13
    mov rsi, rsp
    xor edx, edx
    mov r10d, 8
    syscall
    add rsp, 32
    jmp .sigpipe_done
.sigreturn:
    mov eax, SYS_rt_sigreturn
    syscall
.sigpipe_done:

    mov eax, SYS_socket
    mov edi, AF_INET
    mov esi, SOCK_STREAM
    xor edx, edx
    syscall
    test eax, eax
    js  fatal
    mov [server_fd], eax

    mov eax, SYS_setsockopt
    mov edi, [server_fd]
    mov esi, SOL_SOCKET
    mov edx, SO_REUSEADDR
    lea r10, [reuse_val]
    mov r8d, 4
    syscall

    mov eax, SYS_bind
    mov edi, [server_fd]
    lea rsi, [sockaddr_data]
    mov edx, 16
    syscall
    test eax, eax
    js  fatal

    mov eax, SYS_listen
    mov edi, [server_fd]
    mov esi, 128
    syscall

    mov eax, SYS_fcntl
    mov edi, [server_fd]
    mov esi, 3
    syscall
    or  eax, 0x800
    mov edi, [server_fd]
    mov esi, 4
    mov edx, eax
    mov eax, SYS_fcntl
    syscall

    mov qword [send_buf_ptr], send_buf
    mov dword [snap_count], 0

    call scan_posts

    cmp byte [HOT_RELOAD_BYTE], 1
    jne main_loop
    call check_snapshot
    mov byte [needs_reload], 0

main_loop:
    cmp byte [HOT_RELOAD_BYTE], 1
    jne .no_snap
    call check_snapshot
.no_snap:

    mov eax, [server_fd]
    mov [poll_fds], eax
    mov word [poll_fds+4], POLLIN
    mov word [poll_fds+6], 0
    mov rcx, [sse_count]
    xor ebx, ebx
.spoll:
    cmp rbx, rcx
    jae .pdone
    mov eax, [sse_fds+rbx*4]
    mov [poll_fds+rbx*8+8], eax
    mov word [poll_fds+rbx*8+12], 0
    mov word [poll_fds+rbx*8+14], 0
    inc rbx
    jmp .spoll
.pdone:
    mov edx, -1
    cmp qword [sse_count], 0
    je  .dopoll
    cmp byte [HOT_RELOAD_BYTE], 1
    jne .dopoll
    mov edx, 3000
.dopoll:
    mov eax, SYS_poll
    lea rdi, [poll_fds]
    mov esi, 1
    add rsi, [sse_count]
    syscall
    test eax, eax
    js  main_loop

    test word [poll_fds+6], POLLIN
    jz  .no_acc
.acc_loop:
    mov eax, SYS_accept4
    mov edi, [server_fd]
    xor esi, esi
    xor edx, edx
    mov r10d, SOCK_CLOEXEC
    syscall
    test eax, eax
    js  .no_acc
    mov r12d, eax
    mov edi, r12d
    call handle_connection
    jmp .acc_loop
.no_acc:

    cmp byte [needs_reload], 1
    jne .skl
    call sse_reload_all
    mov byte [needs_reload], 0
    jmp .sdone
.skl:
    cmp qword [sse_count], 0
    je  .sdone
    call sse_keepalives
.sdone:
    jmp main_loop

fatal:
    mov eax, SYS_exit
    mov edi, 1
    syscall

; ---- Snapshot check ----
check_snapshot:
    mov r12, [post_count]
    cmp r12, 0
    je  .no_change

    xor ebx, ebx
    mov r14, snap_data

.slp:
    cmp ebx, [post_count]
    jae .compare

    mov r13, [post_sorted+rbx*8]

    push rbx
    push r14

    mov rdi, r14
    mov rsi, r13
    shl rsi, 6
    lea rsi, [post_fnames+rsi]
    mov rcx, 64
.cp:
    lodsb
    stosb
    test al, al
    jz  .pad
    loop .cp
.pad:
    test rcx, rcx
    jz  .stfile
    mov al, 0
    rep stosb

.stfile:
    mov rdi, path_buf
    lea rsi, [posts_prefix]
    mov ecx, 6
    rep movsb
    mov rsi, r13
    shl rsi, 6
    lea rsi, [post_fnames+rsi]
    mov rdi, rsi
    call strlen_cdecl
    mov rcx, rax
    mov rsi, r13
    shl rsi, 6
    lea rsi, [post_fnames+rsi]
    lea rdi, [path_buf+6]
    rep movsb
    mov byte [rdi], 0

    mov eax, SYS_stat
    mov edi, path_buf
    mov esi, stat_buf
    syscall
    test eax, eax
    js  .nxt

    mov rax, [stat_buf+STAT_ST_SIZE]
    mov [r14+64], rax
    mov rax, [stat_buf+STAT_ST_MTIME]
    mov [r14+72], rax

.nxt:
    pop r14
    pop rbx
    add r14, 80
    inc ebx
    jmp .slp

.compare:
    mov r13d, [post_count]
    cmp r13d, [snap_count]
    jne .changed

    imul eax, r13d, 80
    mov rdi, snap_data
    mov rsi, snap_old
    mov rdx, rax
    call memcmp_routine
    jne .changed

.no_change:
    cmp eax, eax
    ret
.changed:
    mov r13d, [post_count]
    imul ecx, r13d, 80
    mov rdi, snap_old
    mov rsi, snap_data
    rep movsb
    mov [snap_count], r13d
    mov rdi, snap_old
    mov rsi, snap_data
    rep movsb
    mov [snap_count], r13d
    call scan_posts
    mov byte [needs_reload], 1
    mov eax, 1
    cmp eax, 0
    ret

memcmp_routine:
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
    xor ecx, ecx
.mloop:
    cmp rcx, rdx
    je  .meq
    mov al, [r12+rcx]
    cmp al, [r13+rcx]
    jne .mneq
    inc rcx
    jmp .mloop
.meq:
    pop r13
    pop r12
    cmp eax, eax
    ret
.mneq:
    pop r13
    pop r12
    mov eax, 1
    cmp eax, 0
    ret

; ============================================================
section .rodata

http_ok:    db "HTTP/1.1 200 OK", 13, 10
http_ok_len equ $ - http_ok
http_404:   db "HTTP/1.1 404 Not Found", 13, 10
http_404_len equ $ - http_404

ct_html:    db "Content-Type: text/html", 13, 10
ct_html_len equ $ - ct_html
ct_prefix:  db "Content-Type: "
cl_prefix:  db "Content-Length: "
cl_9:       db "Content-Length: 9", 13, 10
cl_9_len    equ $ - cl_9

xcto_hdr:   db "X-Content-Type-Options: nosniff", 13, 10
xcto_hdr_len equ $ - xcto_hdr
rp_hdr:     db "Referrer-Policy: no-referrer", 13, 10
rp_hdr_len  equ $ - rp_hdr

csp_none:   db "Content-Security-Policy: default-src 'self'; script-src 'none'; style-src 'self'; img-src 'self' http: https:; object-src 'none'; base-uri 'none'", 13, 10
csp_none_len equ $ - csp_none
csp_inline: db "Content-Security-Policy: default-src 'self'; script-src 'unsafe-inline'; style-src 'self'; img-src 'self' http: https:; object-src 'none'; base-uri 'none'", 13, 10
csp_inline_len equ $ - csp_inline

conn_close_hdr: db "Connection: close", 13, 10
conn_close_hdr_len equ $ - conn_close_hdr
crlf_str:   db 13, 10

raw405:     db "HTTP/1.1 405 Method Not Allowed", 13, 10
            db "Content-Type: text/html", 13, 10
            db "X-Content-Type-Options: nosniff", 13, 10
            db "Referrer-Policy: no-referrer", 13, 10
            db "Content-Length: 0", 13, 10
            db "Connection: close", 13, 10
            db 13, 10
raw405_len  equ $ - raw405

raw303:     db "HTTP/1.1 303 See Other", 13, 10
            db "Location: /", 13, 10
            db "X-Content-Type-Options: nosniff", 13, 10
            db "Referrer-Policy: no-referrer", 13, 10
            db "Content-Length: 0", 13, 10
            db "Connection: close", 13, 10
            db 13, 10
raw303_len  equ $ - raw303

raw414:     db "HTTP/1.1 414 URI Too Long", 13, 10
            db "Content-Type: text/html", 13, 10
            db "X-Content-Type-Options: nosniff", 13, 10
            db "Referrer-Policy: no-referrer", 13, 10
            db "Content-Length: 0", 13, 10
            db "Connection: close", 13, 10
            db 13, 10
raw414_len  equ $ - raw414

raw431:     db "HTTP/1.1 431 Request Header Fields Too Large", 13, 10
            db "Content-Type: text/html", 13, 10
            db "X-Content-Type-Options: nosniff", 13, 10
            db "Referrer-Policy: no-referrer", 13, 10
            db "Content-Length: 0", 13, 10
            db "Connection: close", 13, 10
            db 13, 10
raw431_len  equ $ - raw431

raw503:     db "HTTP/1.1 503 Service Unavailable", 13, 10
            db "Content-Type: text/html", 13, 10
            db "X-Content-Type-Options: nosniff", 13, 10
            db "Referrer-Policy: no-referrer", 13, 10
            db "Content-Length: 0", 13, 10
            db "Connection: close", 13, 10
            db 13, 10
raw503_len  equ $ - raw503

n404:       db "<h1>404</h1><p>Not found.</p>"
n404_len    equ $ - n404

site_title_str: db SITE_TITLE
site_title_str_len equ $ - site_title_str

doc1:       db "<!DOCTYPE html>", 10, '<html lang="en">', 10, "<head>", 10
            db '<meta charset="UTF-8">', 10
            db '<meta name="viewport" content="width=device-width,initial-scale=1.0">', 10
doc1_len    equ $ - doc1
title1:     db "<title>"
title1_len  equ $ - title1
title2:     db "</title>", 10
title2_len  equ $ - title2
title_sep:  db " &#8212; "
title_sep_len equ $ - title_sep
doc2:       db '<link rel="stylesheet" href="/public/style.css">', 10
doc2_len    equ $ - doc2
sse_scr:    db "<script>", 10, 'new EventSource("/events").onmessage=()=>location.reload();', 10, "</script>", 10
sse_scr_len equ $ - sse_scr
doc3:       db "</head>", 10, "<body>", 10, "<header><a href=", 34, "/", 34, ">"
doc3_len    equ $ - doc3
doc4:       db "</a></header>", 10, "<main>", 10
doc4_len    equ $ - doc4
doc_end:    db "</main>", 10, "</body>", 10, "</html>", 10
doc_end_len equ $ - doc_end

article_tag: db "<article>", 10
article_end: db 10, "</article>", 10
article_end_len equ $ - article_end
h1_tag:     db "<h1>"
h1_end:     db "</h1>", 10
h1_end_len  equ $ - h1_end
time_tag:   db "<time>"
time_end:   db "</time>"

art_time1:  db "<article><time>"
art_time1_len equ $ - art_time1
art_time2:  db '</time> <a href="/posts/'
art_time2_len equ $ - art_time2
art_time3:  db '">'
art_time3_len equ $ - art_time3
art_end:    db "</a></article>", 10
art_end_len equ $ - art_end

; Markdown block tags
p_tag:      db "<p>"
p_end:      db "</p>", 10
ul_tag:     db "<ul>", 10
ul_end:     db "</ul>", 10
ol_tag:     db "<ol>", 10
ol_end:     db "</ol>", 10
li_tag:     db "<li>"
li_end:     db "</li>", 10
hr_str:     db "<hr>", 10

; Markdown inline tags
em_tag:     db "<em>"
em_end:     db "</em>"
strong_tag: db "<strong>"
strong_end: db "</strong>"
code_tag:   db "<code>"
code_end:   db "</code>"
link_tag1:  db '<a href="'
link_tag2:  db '">'
link_end:   db "</a>"
link_bad:   db '<a href="#">'
img_tag1:   db '<img src="'
img_tag2:   db '" alt="'
img_tag3:   db '">'
img_bad:    db '<img src="#" alt=""'

; HTML entities
lt_ent:     db "&lt;"
gt_ent:     db "&gt;"
amp_ent:    db "&amp;"
quot_ent:   db "&quot;"

sse_hdrs:   db "HTTP/1.1 200 OK", 13, 10
            db "Content-Type: text/event-stream", 13, 10
            db "Cache-Control: no-cache", 13, 10
            db "Connection: close", 13, 10
            db 13, 10
sse_hdrs_len equ $ - sse_hdrs
sse_conn:   db ": connected", 10, 10
sse_conn_len equ $ - sse_conn
sse_ka:     db ": keepalive", 10
sse_rld:    db "data: reload", 10, 10

pub_prefix: db "public/"
posts_dir:  db "posts", 0
posts_prefix: db "posts/"

mime_css_str:  db "text/css", 0
mime_js_str:   db "application/javascript", 0
mime_def_str:  db "application/octet-stream", 0

empty_str:  db 0

reuse_val:  dd 1

sockaddr_data:
    dw AF_INET
    dw 0xE420
    dd BIND_ADDR
    dq 0

rcv_timeout_data:
    dq RECV_TIMEOUT_SEC
    dq 0

; ============================================================
trace_off: db "off="
trace_rcl: db " rcl="
trace_typ: db " typ="
trace_nm:  db " nm="
tr_parse_ok: db "OK", 10
tr_parse_fail: db "FAIL", 10
post_dbg_head: db "HDR", 10
post_dbg_get:  db "GET", 10
dbg_find:      db "FIND", 10
dbg_nf:        db "NF", 10

section .data

; ============================================================
section .bss

server_fd:      resd 1
                 alignb 8
client_fd:      resq 1
output_mode:    resb 1
HOT_RELOAD_BYTE: resb 1
needs_reload:   resb 1
                 alignb 8
byte_count:     resq 1
send_buf_ptr:   resq 1

recv_buf:       resb RECV_BUF_SIZE
send_buf:       resb SEND_BUF_SIZE
path_buf:       resb PATH_MAX_LEN
stat_buf:       resb SIZEOF_STAT
dirent_buf:     resb DIRENT_BUF_SIZE

; Post index
post_count:     resq 1
post_fnames:    resb MAX_POSTS * FILENAME_MAX
post_titles:    resb MAX_POSTS * TITLE_MAX_LEN
post_ts_year:   resw MAX_POSTS
post_ts_month:  resb MAX_POSTS
post_ts_day:    resb MAX_POSTS
post_ts_hour:   resb MAX_POSTS
post_ts_min:    resb MAX_POSTS
post_ts_sec:    resb MAX_POSTS
post_has_time:  resb MAX_POSTS
                 alignb 8
post_sorted:    resq MAX_POSTS

; Temporary timestamp during scan
                 alignb 8
ts_year:        resw 1
ts_month:       resb 1
ts_day:         resb 1
ts_hour:        resb 1
ts_min:         resb 1
ts_sec:         resb 1
ts_has_time:    resb 1

; Markdown parser state
in_list:        resb 1
list_ordered:   resb 1
                 alignb 8
list_count:     resq 1
list_lines:     resq 64
list_lens:      resq 64
para_count:     resq 1
para_lines:     resq 128
para_lens:      resq 128

; Post page render state
render_title:   resq 1
render_title_len: resq 1
render_date:    resq 1
render_date_len: resq 1
render_body:    resq 1
render_body_len: resq 1
to_html_size:    resq 1
tmp_buf:        resb 64
trace_buf:      resb 64
scan_dir_fd:    resd 1
                 alignb 8
r8_save:        resq 1

; SSE
sse_count:      resq 1
sse_fds:        resd MAX_SSE_CLIENTS
poll_fds:       resb (1 + MAX_SSE_CLIENTS) * 8

; Snapshot
snap_count:     resd 1
                 alignb 8
snap_data:      resb 4096
snap_old:       resb 4096
