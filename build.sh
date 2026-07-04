#!/bin/sh
set -eu

echo "=== Building massless ==="
nasm -f elf64 -O1 massless.asm -o massless.o
ld -nostdlib -static -T link.ld -e _start massless.o -o massless
strip massless
rm -f massless.o

echo ""
echo "=== Binary info ==="
echo "File size: $(wc -c < massless) bytes"
size massless
echo ""
echo "=== ELF check ==="
echo -n "Dynamic section: "
if readelf -d massless 2>/dev/null | grep -q 'no dynamic'; then echo "none"; else echo "FOUND!"; fi
echo -n "Interpreter: "
if readelf -l massless 2>/dev/null | grep -q 'INTERP'; then echo "PRESENT!"; else echo "none"; fi
echo ""
echo "Build complete: ./massless"
