#!/usr/bin/env bash
# ============================================================
# XRay VLESS + Reality server — one-command deployment
# Traffic is disguised as browsing a popular local website.
#
# Usage:
#   bash deploy.sh                     # defaults (digikala disguise, port 443)
#   DOMAIN=snapp.ir PORT=8443 bash deploy.sh
#
# Env overrides:
#   DOMAIN     disguise SNI domain        (default: www.digikala.com)
#   PORT       listening port             (default: 443)
#   XRAY_TAG   xray docker image tag      (default: 25.12.8)
#   DIR        install directory          (default: /opt/xray-reality)
#   NAME       container name             (default: xray-reality)
# ============================================================
set -euo pipefail

DOMAIN="${DOMAIN:-www.digikala.com}"
PORT="${PORT:-443}"
XRAY_TAG="${XRAY_TAG:-25.12.8}"
DIR="${DIR:-/opt/xray-reality}"
NAME="${NAME:-xray-reality}"
IMAGE="teddysun/xray:${XRAY_TAG}"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- 0. sanity checks ----------
[ "$(id -u)" -eq 0 ] || die "Run as root: sudo bash deploy.sh"
command -v curl >/dev/null 2>&1 || die "curl is required"

# ---------- 1. install docker if missing ----------
if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker..."
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io docker-compose-v2 >/dev/null
fi
docker --version >/dev/null || die "Docker install failed"

if docker compose version >/dev/null 2>&1; then
  DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DC="docker-compose"
else
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-compose-v2 >/dev/null
  DC="docker compose"
fi
log "Docker: $(docker --version)"

# ---------- 2. verify disguise domain supports TLS 1.3 ----------
log "Verifying disguise domain: $DOMAIN"
if ! echo | timeout 10 openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" -tls1_3 -brief 2>&1 | grep -q "CONNECTION ESTABLISHED"; then
  warn "Could not verify $DOMAIN (may still work). Continuing."
fi

# ---------- 3. pull image ----------
log "Pulling $IMAGE"
docker pull "$IMAGE" >/dev/null

# ---------- 4. generate fresh credentials ----------
log "Generating keys + credentials"
KEYOUT="$(docker run --rm "$IMAGE" xray x25519 2>&1)"
# Output labels vary by xray version ("PrivateKey:", "Password (PublicKey):", "Password:")
PRIV="$(printf '%s\n' "$KEYOUT" | grep -i 'privatekey' | grep -oE '[A-Za-z0-9_-]{40,}' | head -1)"
PUB="$(printf '%s\n' "$KEYOUT" | grep -i 'password\|publickey' | grep -oE '[A-Za-z0-9_-]{40,}' | head -1)"
[ -n "$PRIV" ] && [ -n "$PUB" ] || die "Key generation failed. Raw output: $KEYOUT"

UUID="$(cat /proc/sys/kernel/random/uuid)"
SHORT_ID="$(openssl rand -hex 8)"
SPIDER_X="/$(openssl rand -hex 6)"

# ---------- 5. write configs ----------
mkdir -p "$DIR"
cat > "$DIR/config.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": $PORT,
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "$UUID", "flow": "xtls-rprx-vision", "email": "user1" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "$DOMAIN:443",
        "serverNames": ["$DOMAIN"],
        "privateKey": "$PRIV",
        "shortIds": ["$SHORT_ID"]
      }
    },
    "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

cat > "$DIR/docker-compose.yml" <<EOF
services:
  xray:
    image: $IMAGE
    container_name: $NAME
    restart: unless-stopped
    ports:
      - "$PORT:$PORT"
    volumes:
      - ./config.json:/etc/xray/config.json:ro
    logging:
      driver: json-file
      options: { max-size: "10m", max-file: "3" }
EOF
chmod 600 "$DIR/config.json"

# validate before starting
docker run --rm -v "$DIR":/etc/xray "$IMAGE" xray -test -config /etc/xray/config.json >/dev/null 2>&1 \
  || die "Generated config failed validation"

# ---------- 6. start ----------
log "Starting container"
( cd "$DIR" && $DC up -d ) >/dev/null
sleep 2
docker ps --format '{{.Names}} {{.Status}}' | grep -q "$NAME" || die "Container did not start. Check: docker logs $NAME"

# ---------- 7. install user management CLI ----------
# Works via git clone (file next to script) or curl|bash (fetch from GitHub).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || SCRIPT_DIR=""
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/xray-users" ]; then
  install -m 755 "$SCRIPT_DIR/xray-users" /usr/local/bin/xray-users
  log "Installed 'xray-users' CLI (add/list/link/revoke)"
elif curl -fsSL -m 20 "https://raw.githubusercontent.com/teelge/xray-reality-deploy/main/xray-users" -o /usr/local/bin/xray-users 2>/dev/null; then
  chmod 755 /usr/local/bin/xray-users
  log "Installed 'xray-users' CLI from GitHub"
else
  warn "Could not install xray-users CLI (user management)"
fi

# ---------- 8. print results ----------
SERVER_IP="$(curl -sS -m 10 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
SPX_ENC="$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$SPIDER_X" 2>/dev/null || printf '%s' "$SPIDER_X")"
LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUB}&sid=${SHORT_ID}&spx=${SPX_ENC}&type=tcp&headerType=none"

printf '%s\n' "$LINK" > "$DIR/share-link.txt"
chmod 600 "$DIR/share-link.txt"

log "Deployment complete."
echo
echo "=============================================="
echo " Share link (import into v2rayNG / Happ / Streisand):"
echo "=============================================="
echo
echo "$LINK"
echo
echo "=============================================="
echo " Server:  $SERVER_IP:$PORT  (disguise: $DOMAIN)"
echo " Files:   $DIR/  (keep config.json secret!)"
echo " Manage:  cd $DIR && docker compose restart|logs"
echo "=============================================="
