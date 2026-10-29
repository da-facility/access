# The official RustDesk ID server (hbbs) 1.1.16, plus the TCP key exchange that signed-in
# clients require before they send their access token (see secure_tcp.rs). Built from source;
# the relay (hbbr) keeps running the official image.
FROM rust:1.90-bookworm@sha256:3914072ca0c3b8aad871db9169a651ccfce30cf58303e5d6f2db16d1d8a7e58f AS build
# Tag 1.1.16, and the hbb_common it pins.
ARG SERVER_COMMIT=73523b31cfd25d77dee862e6fc9f5e1fb5e485ef
ARG HBB_COMMON_COMMIT=83419b6549636ee39dacef7776c473f5802e08d6
WORKDIR /src
RUN git clone --quiet https://github.com/rustdesk/rustdesk-server.git . \
 && git checkout --quiet "$SERVER_COMMIT" \
 && git submodule update --init --quiet \
 && test "$(git -C libs/hbb_common rev-parse HEAD)" = "$HBB_COMMON_COMMIT"
COPY rendezvous_server.patch hbb_common.patch /patches/
COPY secure_tcp.rs src/secure_tcp.rs
RUN git apply /patches/rendezvous_server.patch \
 && git -C libs/hbb_common apply /patches/hbb_common.patch
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    cargo test --locked --lib secure_tcp \
 && cargo build --release --locked --bin hbbs \
 && cp target/release/hbbs /hbbs

FROM gcr.io/distroless/cc-debian12@sha256:e5d81ddde149641e2a9ba55be4545bc125c67de07508b03ba4c22e6eb0ded5aa
COPY --from=build /hbbs /usr/bin/hbbs
WORKDIR /root
CMD ["hbbs"]
