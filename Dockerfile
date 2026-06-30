FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    STEAMAPPID=4114030 \
    INSTALL_DIR=/opt/riftbreaker \
    WINEPREFIX=/data/.wine \
    WINEARCH=win64 \
    WINEDEBUG=-all,err+all \
    WINEDLLOVERRIDES="mscoree,mshtml=" \
    STEAM_USER=steamuser

RUN dpkg --add-architecture i386 \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        cabextract \
        gosu \
        iproute2 \
        lib32gcc-s1 \
        locales \
        procps \
        tini \
        xauth \
        xvfb \
    && sed -i '/en_US.UTF-8/s/^# //' /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash "${STEAM_USER}" \
    && mkdir -p /opt/steamcmd "${INSTALL_DIR}" \
    && curl -fsSL "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz" \
        | tar -xz -C /opt/steamcmd \
    && chown -R "${STEAM_USER}:${STEAM_USER}" /opt/steamcmd \
    && chmod +x /opt/steamcmd/steamcmd.sh

RUN mkdir -pm755 /etc/apt/keyrings \
    && curl -fsSL -o /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key \
    && curl -fsSL -o /etc/apt/sources.list.d/winehq-bookworm.sources \
        https://dl.winehq.org/wine-builds/debian/dists/bookworm/winehq-bookworm.sources \
    && apt-get update \
    && apt-get install -y --install-recommends winehq-stable \
    && apt-get install -y --no-install-recommends winbind \
    && ln -sf /usr/bin/wine /usr/local/bin/wine \
    && ln -sf /usr/bin/wine /usr/local/bin/wine64 \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o /usr/local/bin/winetricks \
        https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks \
    && chmod +x /usr/local/bin/winetricks

# Download Windows Steam SDK DLLs (tier0_s64.dll, vstdlib_s64.dll, steamclient64.dll)
# App 1007 = Steamworks SDK Redist — official Valve package with Windows DLLs
RUN mkdir -p /opt/steam-sdk-win \
    && chown "${STEAM_USER}:${STEAM_USER}" /opt/steam-sdk-win \
    && su - "${STEAM_USER}" -c " \
        /opt/steamcmd/steamcmd.sh \
            +@sSteamCmdForcePlatformType windows \
            +force_install_dir /opt/steam-sdk-win \
            +login anonymous \
            +app_update 1007 \
            +quit" || true \
    && if find /opt/steam-sdk-win -name "tier0_s64.dll" | grep -q .; then \
        echo '[Dockerfile] Steam SDK DLLs downloaded successfully.'; \
       else \
        echo '[Dockerfile] WARNING: Steam SDK DLLs missing after build — rebuild with --no-cache if this is unexpected.' >&2; \
       fi

COPY --chown=${STEAM_USER}:${STEAM_USER} scripts/ /scripts/

RUN sed -i 's/\r$//' /scripts/*.sh \
    && chmod +x /scripts/*.sh

WORKDIR /home/${STEAM_USER}

EXPOSE 6321/tcp 6321/udp

HEALTHCHECK --interval=15s --timeout=5s --start-period=120s --retries=5 \
    CMD pgrep -f DedicatedServer.exe >/dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/scripts/docker-entrypoint.sh"]