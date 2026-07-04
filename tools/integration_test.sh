#!/bin/bash
set -eu

PORT=8420
BASE="http://127.0.0.1:$PORT"
PASS=0
FAIL=0

check() {
    local label="$1"
    local expected="$2"
    local actual="$3"
    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS+1))
        echo "ok $label"
    else
        FAIL=$((FAIL+1))
        echo "FAIL $label: expected '$expected' got '$actual'"
    fi
}

check_contains() {
    local label="$1"
    local pattern="$2"
    local haystack="$3"
    if echo "$haystack" | grep -q "$pattern"; then
        PASS=$((PASS+1))
        echo "ok $label"
    else
        FAIL=$((FAIL+1))
        echo "FAIL $label: pattern '$pattern' not found"
    fi
}

echo "=== Integration Tests ==="

# Build and start server
zig build -Doptimize=ReleaseSafe > /dev/null 2>&1
echo "Starting server..."
./zig-out/bin/massless > /dev/null 2>&1 &
PID=$!
sleep 1

cleanup() { kill "$PID" 2>/dev/null || true; }
trap cleanup EXIT

# ---------- 1. HEAD response (max-time needed for keep-alive) ----------
echo "--- HEAD checks ---"

HEAD_BODY_LEN=$(curl -sS --max-time 3 -X HEAD "$BASE/" 2>/dev/null | wc -c)
check "HEAD / body empty (0 bytes)" "0" "${HEAD_BODY_LEN:--1}"

HEAD_HDR=$(curl -sS --max-time 3 -X HEAD -D- -o /dev/null "$BASE/" 2>&1 || true)
check_contains "HEAD / has Content-Length" "content-length" "$HEAD_HDR"
check_contains "HEAD / 200 OK" "200" "$HEAD_HDR"

HEAD_CSS_HDR=$(curl -sS --max-time 3 -X HEAD -D- -o /dev/null "$BASE/public/style.css" 2>&1 || true)
check_contains "HEAD /public/style.css 200" "200" "$HEAD_CSS_HDR"

HEAD_404_BD=$(curl -sS --max-time 3 -X HEAD "$BASE/nope" 2>/dev/null | wc -c)
check "HEAD /nope body empty" "0" "${HEAD_404_BD:--1}"

# ---------- 2. GET unchanged ----------
echo "--- GET checks ---"
GET_OUT=$(curl -sS --max-time 3 "$BASE/" 2>&1 || true)
check_contains "GET / has HTML" "<html" "$GET_OUT"

# ---------- 3. Unsupported method ----------
echo "--- 405 checks ---"
POST_CODE=$(curl -sS --max-time 3 -o /dev/null -w '%{http_code}' -X POST "$BASE/" 2>&1 || echo "000")
check "POST / 405" "405" "${POST_CODE:-000}"

PUT_CODE=$(curl -sS --max-time 3 -o /dev/null -w '%{http_code}' -X PUT "$BASE/" 2>&1 || echo "000")
check "PUT / 405" "405" "${PUT_CODE:-000}"

PATCH_CODE=$(curl -sS --max-time 3 -o /dev/null -w '%{http_code}' -X PATCH "$BASE/" 2>&1 || echo "000")
check "PATCH / 405" "405" "${PATCH_CODE:-000}"

DELETE_CODE=$(curl -sS --max-time 3 -o /dev/null -w '%{http_code}' -X DELETE "$BASE/" 2>&1 || echo "000")
check "DELETE / 405" "405" "${DELETE_CODE:-000}"

# ---------- 4. Redirect ----------
echo "--- Redirect check ---"
REDIR_CODE=$(curl -sS --max-time 3 -o /dev/null -w '%{http_code}' "$BASE/posts" 2>&1 || echo "000")
check "/posts redirect 303" "303" "${REDIR_CODE:-000}"

# ---------- 5. Slug hygiene ----------
echo "--- Slug checks ---"

SLUG_OK=$(curl -sS --max-time 3 -o /dev/null -w '%{http_code}' "$BASE/posts/rust-and-zig" 2>&1 || echo "000")
check "valid slug 200" "200" "${SLUG_OK:-000}"

SLUG_SLASH=$(curl -sS --max-time 3 -o /dev/null -w '%{http_code}' "$BASE/posts/foo/bar" 2>&1 || echo "000")
check "slug with slash 404" "404" "${SLUG_SLASH:-000}"

SLUG_DOT=$(curl -sS --max-time 3 -o /dev/null -w '%{http_code}' --path-as-is "$BASE/posts/../build.zig" 2>&1 || echo "000")
check "slug with dot-dot 404" "404" "${SLUG_DOT:-000}"

SLUG_PCT=$(curl -sS --max-time 3 -o /dev/null -w '%{http_code}' --path-as-is "$BASE/posts/%2e%2e/build.zig" 2>&1 || echo "000")
check "slug percent-encoded 404" "404" "${SLUG_PCT:-000}"

SLUG_NUL=$(curl -sS --max-time 3 -o /dev/null -w '%{http_code}' --path-as-is "$BASE/posts/a%00b" 2>&1 || echo "000")
check "slug with NUL 404" "404" "${SLUG_NUL:-000}"

# ---------- 6. SSE stress ----------
echo "--- SSE stress check ---"
SSE_OUT=$(timeout 5 curl -sS -N --max-time 4 "$BASE/events" 2>&1 || true)
check_contains "SSE connect message" "connected" "$SSE_OUT"

# Trigger reload by touching a post
touch posts/2026-06-25-our-father.md
sleep 2

# Verify normal GET still works after SSE activity
GET_AFTER=$(curl -sS --max-time 3 -o /dev/null -w '%{http_code}' "$BASE/" 2>&1 || echo "000")
check "GET after SSE activity" "200" "${GET_AFTER:-000}"

# ---------- Summary ----------
TOTAL=$((PASS + FAIL))
echo ""
echo "$PASS/$TOTAL passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
echo "All integration tests passed."
