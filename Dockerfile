# aMule 3 (amuled + amuleweb + amulecmd) from the official amule-org repo.
# Multi-stage: builds with CMake and leaves a slim runtime image.

# trixie and not bookworm: aMule 3 needs wxWidgets with wxUSE_WEBREQUEST=1
# (libcurl backend); bookworm's wx 3.2.2 ships with it disabled, trixie's
# 3.2.8 enables it.
FROM debian:trixie-slim AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        cmake \
        git \
        ca-certificates \
        pkg-config \
        libwxgtk3.2-dev \
        libglib2.0-dev \
        libcrypto++-dev \
        libboost-dev \
        zlib1g-dev \
        libpng-dev \
        libupnp-dev \
        gettext \
    && rm -rf /var/lib/apt/lists/*

ARG AMULE_REPO=https://github.com/amule-org/amule
ARG AMULE_VERSION=3.0.1

RUN git clone --depth 1 --branch "${AMULE_VERSION}" "${AMULE_REPO}" /src

# ENABLE_IP2COUNTRY defaults to ON since 3.0.1 and hard-fails at configure
# without libmaxminddb; the country flags are GUI-only (they never reach
# amuled or the WebUI), so we opt out instead of pulling in the dependency.
# DEFAULT_VERSION_CHECK=OFF is the upstream recommendation for packagers:
# it only sets the initial value of [eMule] NewVersionCheck, which can still
# be flipped with EMULE__NEWVERSIONCHECK=1.
RUN cmake -B /build /src \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_MONOLITHIC=OFF \
        -DBUILD_REMOTEGUI=OFF \
        -DBUILD_DAEMON=ON \
        -DBUILD_WEBSERVER=ON \
        -DBUILD_AMULECMD=ON \
        -DENABLE_UPNP=ON \
        -DENABLE_IP2COUNTRY=NO \
        -DDEFAULT_VERSION_CHECK=OFF \
    && cmake --build /build -j"$(nproc)" \
    && DESTDIR=/out cmake --install /build

FROM debian:trixie-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        libwxbase3.2-1t64 \
        libglib2.0-0t64 \
        libcrypto++8t64 \
        libpng16-16t64 \
        libupnp17t64 \
        zlib1g \
        ca-certificates \
        curl \
        gosu \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -g 1000 amule \
    && useradd -m -u 1000 -g amule -d /home/amule amule

COPY --from=build /out/usr/local /usr/local

# Verify the binaries have all their libraries resolved
RUN ldd /usr/local/bin/amuled /usr/local/bin/amuleweb /usr/local/bin/amulecmd \
        | { ! grep "not found"; }

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENV AMULE_HOME=/config

EXPOSE 4662/tcp 4672/udp 4711/tcp 4712/tcp

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["amuled"]
