/* Minimal linker script for massless — static ELF, no interpreter, no dynamic sections */
SECTIONS {
    . = 0x400000 + SIZEOF_HEADERS;
    .text   : { *(.text)   }
    .rodata : { *(.rodata) }
    . = ALIGN(0x1000);
    .data   : { *(.data)   }
    .bss    : { *(.bss)    *(COMMON) }
    /DISCARD/ : {
        *(.comment)
        *(.note*)
        *(.eh_frame*)
        *(.gnu*)
        *(.hash)
        *(.dynsym)
        *(.dynstr)
        *(.interp)
        *(.dynamic)
        *(.rela*)
        *(.rel*)
        *(.plt)
        *(.got*)
    }
}
