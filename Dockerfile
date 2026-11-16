# massless: static musl binary with the whole site baked in, on scratch.
# Build: docker build -t massless --build-arg SITE_URL=https://example.org .
# Run:   docker run -p 8420:8420 massless

FROM rust:1-alpine AS build
RUN apk add --no-cache musl-dev
WORKDIR /src
COPY Cargo.toml Cargo.lock build.rs LICENSE ./
COPY vendor/ vendor/
COPY src/ src/
COPY templates/ templates/
COPY posts/ posts/
# Absolute links in the Atom feed (empty = site-relative).
ARG SITE_URL=""
# x86-64-v2 at most: prod is EPYC-Rome. Never target-cpu=native (SIGILL).
# With --target, these flags apply to the binary only, not to build.rs.
ENV RUSTFLAGS="-C target-cpu=x86-64-v2"
RUN cargo build --release --locked --target x86_64-unknown-linux-musl \
    && cp target/x86_64-unknown-linux-musl/release/massless /massless

FROM scratch
COPY --from=build /massless /massless
USER 65532:65532
EXPOSE 8420
# PID 1 without a SIGTERM handler ignores SIGTERM; there is no state to
# flush, so stop at once instead of waiting for the kill timeout.
STOPSIGNAL SIGKILL
ENTRYPOINT ["/massless"]
