# === Build stage ===
FROM alpine:3.21 AS build
RUN apk add curl
RUN curl -fsSL https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz | tar xJ -C /usr/local
ENV PATH=/usr/local/zig-x86_64-linux-0.16.0:$PATH
WORKDIR /app
COPY build.zig build.zig
COPY src/ src/
RUN zig build -Doptimize=ReleaseSmall --prefix /out

# === Runtime stage ===
FROM scratch
COPY --from=build /out/bin/massless /
COPY posts /posts
COPY public /public
EXPOSE 8080
CMD ["/massless"]