# Build
FROM rust:1.90-bookworm AS build
WORKDIR /src
# python3 runs the notices generator below (installed only if the image lacks it).
RUN command -v python3 >/dev/null || \
    (apt-get update && apt-get install -y --no-install-recommends python3 && \
     rm -rf /var/lib/apt/lists/*)

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

# Notices for the crates and the Rust standard library statically linked into
# the binary, from the tree just built. The generator fails on a crate without
# license text and on a manifest that does not declare the root LICENSE.
COPY scripts/rust-notices.py scripts/
RUN python3 -I scripts/rust-notices.py --target host --title eko-relay --own-license Unlicense \
      --out /notices/Third-Party-Notices.txt --rust-std /notices/Rust-Licenses.html && \
    test -s /notices/Third-Party-Notices.txt && test -s /notices/Rust-Licenses.html

# Runtime
FROM debian:bookworm-slim
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/* && \
    useradd --system --uid 10001 --home /data --shell /usr/sbin/nologin eko && \
    mkdir -p /data && chown eko:eko /data

COPY --from=build /src/target/release/eko-relay /usr/local/bin/eko-relay
# Base-image packages keep their notices in /usr/share/doc/*/copyright.
COPY --from=build /notices/ /usr/share/doc/eko-relay/

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
