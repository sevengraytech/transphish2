# Evilginx 2 + Protective WAF — Docker Example

⚠️  **LEGAL / OPERATIONAL WARNING**

Evilginx is a phishing / reverse-proxy tool. It can be used to capture
credentials and session tokens by proxying real authentication flows.

Only use this project in **authorised** security assessments, on systems you
own or have **explicit written permission** to test. The files here are
examples for understanding how Evilginx is packaged and how a protective WAF
layer is structured — they are not an endorsement of any activity outside your
authorised scope.

---

## Layout

```
evilginx/
├── Dockerfile              # Evilginx 2 binary image (downloads from GitHub)
├── waf.Dockerfile          # WAF image (Flask + bot_shield + gunicorn)
├── docker-compose.yml      # Two services: waf (front) + evilginx (back)
├── .dockerignore           # Excludes logs, secrets, .git, etc. from images
├── waf_requirements.txt    # WAF Python deps (flask, gunicorn, requests, redis)
├── bot_shield.py           # Multi-layer bot/scanner detection module
├── waf_app.py              # WAF reverse proxy app (bot_shield + proxy to Evilginx)
├── config/
│   ├── evilginx/
│   │   ├── phishlets/     # Your phishlet YAML files (drop here)
│   │   └── certs/         # Evilginx-managed TLS certs
│   └── waf/               # Static WAF config (if any)
├── logs/
│   ├── evilginx/          # evilginx.log + other Evilginx output
│   └── waf/               # bot_shield.log + gunicorn logs
├── certs/                 # TLS certs for WAF (if WAF terminates TLS)
│   ├── waf.crt
│   └── waf.key
├── .env.example            # Example env vars (copy to .env, fill in, DO NOT COMMIT .env)
└── README.md               # This file
```

## Architecture

```
Client (browser / tester)
    │
    ▼  HTTPS :443 / HTTP :80
┌─────────────────────────────────────────────┐
│  WAF container (evilginx-waf)               │
│  - Flask + gunicorn                          │
│  - bot_shield.py runs 10 detection layers    │
│    on every request before proxying          │
│  - Blocked requests → obfuscated 404/500     │
│  - Approved requests → proxied to Evilginx   │
└────────────────┬────────────────────────────┘
                 │  HTTP (internal Docker network, :8080)
                 ▼
┌─────────────────────────────────────────────┐
│  Evilginx container (evilginx)              │
│  - Evilginx 2 binary                         │
│  - INTERNAL ONLY — no host ports exposed     │
│  - Serves phishlets, proxies auth flows      │
│  - Logs to /config/logs/                    │
└─────────────────────────────────────────────┘
```

The WAF is the **only** ingress. Evilginx is not reachable from the host
network at all (no published ports). The only way to reach Evilginx is through
the WAF, which runs bot detection first.

## What bot_shield.py does (on every request)

1. `/robots.txt` — restrictive policy (disallows login, api, admin paths)
2. Header sanity checks — no UA, no Accept, control chars in UA
3. User-Agent allow/block lists — known scanners blocked; known-good bots allowed
4. Per-IP rate limiting (+ 404 flood detection — scanners hammering known-bad paths get banned)
5. Honeypot form field — injected into every HTML form; bots that auto-fill it get blocked on POST
6. Honeypot links — fake paths (`/wp-login.php`, `/.env`, `/phpmyadmin`, etc.) that log bot hits
7. JS + proof-of-work challenge — on login/signup/auth endpoints; requires a real browser
8. Obfuscated/misleading block responses — random 404/500/502/503 to confuse scanners
9. Custom WAF rules — block access to Evilginx-probe paths (`/phishlet`, `/capture`, etc.)
10. Structured logging — every bot event logged with IP, UA, path, reason

## Run (test environment)

```sh
cd ~/Desktop/evilginx

# Create directories for config + logs
mkdir -p config/evilginx/phishlets config/evilginx/certs
mkdir -p config/waf
mkdir -p logs/evilginx logs/waf

# Clone the env template and fill in your values
cp .env.example .env
# Edit .env — at minimum set BOT_SHIELD_SECRET and a strong WAF_FLASK_SECRET

# Build both images
docker compose build

# Start
docker compose up -d

# Watch WAF logs (bot_shield events + proxy activity)
docker compose logs -f waf

# Watch Evilginx logs
docker compose logs -f evilginx

# Confirm both are healthy
docker compose ps
# or hit the WAF health endpoint (from inside the network):
docker compose exec waf python -c "import requests; print(requests.get('http://evilginx:8080', timeout=3).status_code)"

# Stop
docker compose down
```

To rebuild a different Evilginx version, set the build arg:

```sh
docker compose build --build-arg EVILGINX_TAG=v2.5.0 evilginx
docker compose up -d evilginx
```

## Configuration

All secrets and tuning are env-var driven — nothing hardcoded.

### WAF env vars

| Variable | Default | Purpose |
|---|---|---|
| `WAF_BACKEND_URL` | `http://evilginx:8080` | Evilginx backend the WAF proxies to |
| `WAF_PROXY_TIMEOUT` | `30` | Seconds to wait for Evilginx backend |
| `WAF_FLASK_SECRET` | random per process | Flask session secret (set a real one in prod) |
| `WAF_TLS_CERT` / `WAF_TLS_KEY` | (unset) | If set, WAF terminates TLS on its own listener |

### bot_shield env vars

| Variable | Default | Purpose |
|---|---|---|
| `BOT_SHIELD_RATE_LIMIT_MAX` | `80` | Max requests per IP per window |
| `BOT_SHIELD_RATE_LIMIT_WINDOW` | `60` | Rate-limit window in seconds |
| `BOT_SHIELD_RATE_LIMIT_BAN` | `600` | Ban duration (seconds) after exceeding limit |
| `BOT_SHIELD_TOO_FAST` | `3` | Min seconds between page load and POST before flagging |
| `BOT_SHIELD_NO_REFERRER` | `block` | Policy for POSTs with no Referer: block / challenge / log / allow |
| `BOT_SHIELD_NO_COOKIE` | `allow` | Policy for requests with no cookies |
| `BOT_SHIELD_OBFUSCATE` | `true` | Return misleading status codes on blocks |
| `BOT_SHIELD_LOG_FILE` | `/logs/bot_shield.log` | Where to write bot_event logs |
| `BOT_SHIELD_STORE` | `memory` | `memory` or `redis` |
| `BOT_SHIELD_REDIS_URL` | (unset) | Redis URL if `STORE=redis` |
| `BOT_SHIELD_BLOCKED_IPS` | (unset) | Comma-separated manual IP blocklist |
| `BOT_SHIELD_SECRET` | random per process | HMAC secret for challenge tokens (set a real one in prod) |
| `BOT_SHIELD_HONEYTOKEN` | random per process | Canay token embedded in pages (detect scraping) |

## TLS

The WAF can terminate TLS itself if you mount certs and set `WAF_TLS_CERT` /
`WAF_TLS_KEY`. Alternatively, put nginx/caddy in front of the WAF for TLS
termination and let the WAF run plain HTTP on an internal port.

For the WAF to terminate TLS, mount certs into the waf container and set the
env vars, then override the gunicorn command to listen with `--certfile` /
`--keyfile`:

```yaml
# Example: WAF terminates TLS
services:
  waf:
    volumes:
      - ./certs:/certs:ro
    environment:
      - WAF_TLS_CERT=/certs/waf.crt
      - WAF_TLS_KEY=/certs/waf.key
    command: ["gunicorn", "--bind", "0.0.0.0:443",
               "--certfile", "/certs/waf.crt",
               "--keyfile", "/certs/waf.key",
               "--workers", "2", "--threads", "4",
               "--access-logfile", "/logs/gunicorn-access.log",
               "--error-logfile", "/logs/gunicorn-error.log",
               "waf_app:app"]
```

## Phishlets

Drop your phishlet YAML files into `./config/evilginx/phishlets/`. Evilginx
reads them from `/config/phishlets` inside its container (the volume mount).

The Evilginx Dockerfile downloads the binary from the GitHub release specified
by `EVILGINX_TAG` (default `v2.4.0`). Verify the exact release asset name on
the release page you target and adjust the `RUN curl` line in `Dockerfile` if
it changes.

## Testing your protection

In an authorised test:

1. Start the stack.
2. Send a normal browser request to the WAF — it should reach Evilginx.
3. Send requests with scanner UAs (`sqlmap`, `curl`, `python-requests`) — they
   should be blocked at the WAF with obfuscated responses.
4. Send requests hitting honeypot paths (`/wp-login.php`, `/.env`) — they
   should be logged and served a fake page.
5. Send many rapid requests from one IP — rate limiting should kick in and ban.
6. Check `./logs/waf/bot_shield.log` for structured bot_event entries.

## What this does NOT do

- It does not legitimise any activity outside your authorised scope.
- It does not make Evilginx undetectable to a determined human adversary.
- It does not replace good operational security (secrets management, network
  isolation, logging review, takedown procedures).
- The default Evilginx binary download URL may need updating for newer releases.

## Files summary

| File | Lines | Purpose |
|---|---|---|
| `bot_shield.py` | ~1100 | Multi-layer bot detection module (framework-agnostic core + Flask integration) |
| `waf_app.py` | ~500 | WAF Flask app: bot_shield + reverse proxy to Evilginx, health/status endpoints |
| `waf.Dockerfile` | ~85 | Builds the WAF image (Python 3.11-slim, gunicorn, non-root) |
| `Dockerfile` | ~72 | Builds the Evilginx image (downloads binary, non-root, config dir) |
| `docker-compose.yml` | ~150 | Two-service stack: waf (front, public) + evilginx (back, internal) |
| `waf_requirements.txt` | ~6 | WAF Python deps |
| `.dockerignore` | ~90 | Excludes logs, secrets, .git, etc. from both images |
| `.env.example` | ~40 | Example env vars (copy to .env, fill in, don't commit .env) |
| `README.md` | (this file) | Documentation |
