# Build
FROM rust:1.90-bookworm AS build
WORKDIR /src

# Dependency layer first so source edits do not re-download the world.
COPY Cargo.toml Cargo.lock ./
RUN mkdir -p src && \
    echo 'fn main() {}' > src/main.rs && \
    echo '' > src/lib.rs && \
    cargo build --release --locked && \
    rm -rf src

COPY src ./src
# cargo skips a rebuild when only mtime changed; force the real sources in.
RUN touch src/main.rs src/lib.rs && cargo build --release --locked

# Runtime
FROM debian:bookworm-slim
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/* && \
    useradd --system --uid 10001 --home /data --shell /usr/sbin/nologin eko && \
    mkdir -p /data && chown eko:eko /data

COPY --from=build /src/target/release/eko-relay /usr/local/bin/eko-relay

USER 10001:10001
WORKDIR /data
VOLUME ["/data"]
EXPOSE 8080

ENV EKO_BIND=0.0.0.0:8080 \
    EKO_DATABASE=/data/relay.db

# The relay holds ciphertext it cannot read, but it still holds credentials and
# metadata, so it runs unprivileged with a read-only root filesystem (set in
# compose) and only /data writable.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD ["/usr/local/bin/eko-relay", "--healthcheck"]

ENTRYPOINT ["/usr/local/bin/eko-relay"]
