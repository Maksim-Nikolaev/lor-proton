FROM debian:trixie-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        autoconf \
        bison \
        ca-certificates \
        curl \
        flex \
        gcc \
        gcc-mingw-w64-x86-64 \
        git \
        libc6-dev \
        make \
        patch \
        perl \
        python3 \
    && rm -rf /var/lib/apt/lists/*

RUN git config --system user.email "builder@localhost" \
    && git config --system user.name "builder" \
    && git config --system --add safe.directory '*'
