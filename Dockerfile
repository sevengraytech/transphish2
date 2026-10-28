# ─────────────────────────────────────────────────────────────────────────────
# Evilginx 3 — Production Dockerfile
# ─────────────────────────────────────────────────────────────────────────────

FROM python:3.11-slim

# ── Build arguments ──────────────────────────────────────────────────────────
ARG EVILGINX_TAG=v3.3.0

# ── Install runtime dependencies ─────────────────────────────────────────────
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl ca-certificates python3 unzip dos2unix && \
    rm -rf /var/lib/apt/lists/*

# ── Download and unpack Evilginx ─────────────────────────────────────────────
WORKDIR /opt/evilginx
RUN curl -fsSL "https://github.com/kgretzky/evilginx2/releases/download/${EVILGINX_TAG}/evilginx-${EVILGINX_TAG}-linux-64bit.zip" \
    -o evilginx.zip && \
    unzip -o evilginx.zip && \
    ls -la evilginx && \
    chmod +x evilginx && \
    mv evilginx /usr/local/bin/evilginx && \
    /usr/local/bin/evilginx -h && \
    rm -rf /opt/evilginx

# ── Create non-root user ────────────────────────────────────────────────────
RUN addgroup --system evilginx && \
    adduser --system --ingroup evilginx --no-create-home --shell /usr/sbin/nologin evilginx

# ── Copy phishlets from Evilginx release ─────────────────────────────────────
RUN mkdir -p /tmp/evilginx-phishlets && \
    curl -fsSL "https://github.com/kgretzky/evilginx2/releases/download/${EVILGINX_TAG}/evilginx-${EVILGINX_TAG}-linux-64bit.zip" \
    -o /tmp/evilginx.zip && \
    unzip -o /tmp/evilginx.zip -d /tmp/evilginx-phishlets && \
    mkdir -p /config/phishlets && \
    # Try multiple possible locations in the zip
    cp /tmp/evilginx-phishlets/phishlets/* /config/phishlets/ 2>/dev/null || \
    cp /tmp/evilginx-phishlets/evilginx/phishlets/* /config/phishlets/ 2>/dev/null || \
    cp /tmp/evilginx-phishlets/*/phishlets/* /config/phishlets/ 2>/dev/null || true && \
    chown -R evilginx:evilginx /config/phishlets && \
    ls -la /config/phishlets/ && \
    rm -rf /tmp/evilginx-phishlets /tmp/evilginx.zip

# ── Create config directories ────────────────────────────────────────────────
RUN mkdir -p /config/phishlets /config/certs /config/logs && \
    chown -R evilginx:evilginx /config

# ── Copy entrypoint ──────────────────────────────────────────────────────────
COPY evilginx-entrypoint.sh /usr/local/bin/evilginx-entrypoint.sh
RUN dos2unix /usr/local/bin/evilginx-entrypoint.sh && \
    chmod +x /usr/local/bin/evilginx-entrypoint.sh

# ── Expose ports ─────────────────────────────────────────────────────────────
EXPOSE 80 443 53/udp

# ── Default command ──────────────────────────────────────────────────────────
ENTRYPOINT ["/usr/local/bin/evilginx-entrypoint.sh"]