---
title: rust and zig are the only two languages you will ever need
---

There are languages that protect you from the machine. There are languages
that give you the machine. Rust and Zig are the only two that do either one
completely, without compromise, on every platform that matters. Between them,
every problem is covered.

## Rust

Rust solves the problem that C++ spent forty years failing to solve: how to
write systems software without memory bugs. It does this with a single idea
that no mainstream language had tried before. Ownership.

Every value in Rust has exactly one owner at a time. References are borrows
with statically enforced lifetimes. The compiler proves at build time that no
reference outlives the data it points to. There is no garbage collector.
There is no reference counting unless you ask for it. There is no runtime
overhead for memory safety. The checks happen once, at compile time, and then
they are gone from the binary.

This eliminates use-after-free, double-free, null pointer dereference, buffer
overflow, and data races. These are not minor bugs. They are the majority of
critical security vulnerabilities in every large C and C++ codebase. Rust
makes them impossible in safe code. You can still write unsafe code when you
need to. The keyword is in the name. It is explicit. It is grepable. It is
contained.

The type system catches errors that C lets through silently. Algebraic data
types with exhaustive pattern matching mean you cannot forget to handle a
case. The compiler tells you where your match is incomplete and refuses to
compile until you fix it. Result and Option types make error handling
mandatory. There is no null. There are no unchecked exceptions. Every
possible failure path is visible in the type signature.

Traits provide polymorphism without inheritance. They are implemented
separately from type definitions. You can implement your trait for someone
else's type. You can add functionality to standard library types without
wrapping them. This is composition at the language level.

Cargo is the right build system. One file declares dependencies. One command
builds, tests, documents, and publishes. There is no CMake. There is no
autotools. There is no header-only library downloaded from a wiki page. The
ecosystem is curated through crates.io with semantic versioning enforced at
the package manager level. You can pin versions. You can audit dependencies.
You can reproduce a build from three years ago because the lockfile captures
the exact dependency graph.

Rust is the correct choice for anything that must not crash. Browsers.
Operating system kernels. Databases. Network services that handle untrusted
input. Cryptographic libraries. File systems. Anything where a memory bug
means a security boundary is crossed.

## Zig

Zig solves a different problem. Rust is safe by default with escape hatches.
Zig gives you the machine directly and trusts you to use it. There is no
borrow checker. No lifetimes. No ownership model. You allocate memory
explicitly. You free it explicitly. You pass allocators as parameters so the
caller controls where memory lives. There is no hidden allocation anywhere in
the standard library.

Comptime is Zig's defining feature. Any block of code can be marked comptime
and executed at compile time. Types are first-class values that you construct,
pass to functions, and return from functions. Generics are implemented by
writing normal functions that take types as parameters and return types as
results. There is no separate template language. There is no macro system.
Comptime is just Zig, evaluated early.

This is simpler than it sounds and more powerful than it looks. A JSON parser
written at comptime can parse a configuration file and produce a typed struct
whose fields match the schema. A build script is a Zig program that imports
the standard library. The entire language is available at compile time without
learning a second syntax.

There is no hidden control flow. No operator overloading. No exceptions. No
destructors that run at the end of a scope. No constructors that run before
main. You can look at a line of Zig and see every function call it might make.
There is no magic. There is only the code you wrote.

Debug builds include runtime safety checks. Out-of-bounds access panics.
Integer overflow in debug mode panics. These checks are removed in release
builds where performance matters. The safety is opt-in at the build system
level, not at the language level. You choose the tradeoff per compilation
mode.

C interop is trivial. Zig can import C headers directly. It can translate C
types and functions without bindings generators or FFI declarations. You can
call C from Zig and Zig from C with no overhead and no ceremony. The Zig
compiler includes a C compiler. Cross-compilation works out of the box by
shipping LLVM and linker support for every target. You set the target triple
and build. No toolchain dance. No sysroot configuration.

Zig is the correct choice for anything where you want full control. Kernels.
Embedded firmware. Game engines. Language runtimes. Anywhere you would have
used C but want better ergonomics, a real build system, and compile-time code
execution without a preprocessor.

## why you need both

Rust and Zig are not competitors. They occupy different points on the
control-safety spectrum. Rust says the machine is dangerous and the compiler
should prove your code is correct before it runs. Zig says the machine is
knowable and the language should get out of your way while you reason about
it.

For a networked service that handles user data, Rust. The borrow checker
costs development speed and pays it back in production. You will never debug a
use-after-free at three in the morning. You will never ship a data race to
users. The compiler carries the burden.

For a kernel module or an embedded system where every allocation is
intentional and every byte is accounted for, Zig. The language does not make
assumptions about your memory model. It gives you pointers and lets you
decide. Comptime replaces the preprocessor, the build system, and the code
generator with one mechanism you already know.

For everything else, the choice depends on which tradeoff you prefer. But the
set of problems not well served by either language is empty.

What about the others? C is Zig with forty years of baggage and no comptime.
C++ is Rust with forty years of baggage and no borrow checker. Go is for
network services but leaves you with a garbage collector and no control over
allocation. Python is for scripts that outgrew bash. Java is for enterprises
that measure productivity in lines of code written. None of them are wrong.
None of them are necessary if you have Rust and Zig.

Two languages. Two philosophies. One covers safety. One covers control. That
is all there is.
