# === Build stage ===
FROM alpine:3.21 AS build
RUN apk add curl
ARG ZIG_VERSION=0.16.0
ARG ZIG_SHA256=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
RUN curl -fsSL https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz \
    -o /tmp/zig.tar.xz \
    && echo "${ZIG_SHA256}  /tmp/zig.tar.xz" | sha256sum -c \
    && tar xJf /tmp/zig.tar.xz -C /usr/local \
    && rm /tmp/zig.tar.xz
ENV PATH=/usr/local/zig-x86_64-linux-${ZIG_VERSION}:$PATH
WORKDIR /app
COPY build.zig build.zig
COPY src/ src/
RUN zig build -Doptimize=ReleaseSmall --prefix /out

# === Runtime stage ===
FROM scratch
COPY --from=build /out/bin/massless /
COPY posts /posts
COPY public /public
EXPOSE 8420
CMD ["/massless"]
