#!/usr/bin/env bash
# Add a new user (client) to a running XRay Reality deployment.
# Usage:
#   bash add-user.sh              # auto label
#   bash add-user.sh myfriend     # custom label
# Env:
#   DIR   install dir (default /opt/xray-reality)
#   NAME  container name (default xray-reality)
set -euo pipefail

DIR="${DIR:-/opt/xray-reality}"
NAME="${NAME:-xray-reality}"
LABEL="${1:-user$(date +%s)}"

# locate config (repo layout: DIR/config.json, or DIR/xray/config.json)
CONFIG=""
for c in "$DIR/config.json" "$DIR/xray/config.json"; do
  [ -f "$c" ] && CONFIG="$c" && break
done
[ -n "$CONFIG" ] || { echo "config.json not found under $DIR"; exit 1; }

# add the new client + print what we need for the share link
OUT="$(python3 - "$CONFIG" "$LABEL" <<'PY'
import json, sys, uuid
cfg, label = sys.argv[1], sys.argv[2]
c = json.load(open(cfg))
ib = c["inbounds"][0]
rs = ib["streamSettings"]["realitySettings"]
new = {"id": str(uuid.uuid4()), "flow": "xtls-rprx-vision", "email": label}
ib["settings"].setdefault("clients", []).append(new)
json.dump(c, open(cfg, "w"), indent=2)
print(new["id"], ib["port"], rs["serverNames"][0], rs["shortIds"][0], rs["privateKey"])
PY
)"
read -r UUID PORT SNI SHORT_ID PRIV <<< "$OUT"

# derive public key from the private key (xray x25519 -i <priv>)
IMAGE_TAG="$(docker inspect "$NAME" --format '{{.Config.Image}}' 2>/dev/null || echo teddysun/xray:25.12.8)"
PUB="$(docker run --rm "$IMAGE_TAG" xray x25519 -i "$PRIV" 2>&1 | grep -i 'password' | grep -oE '[A-Za-z0-9_-]{40,}' | head -1)"
[ -n "$PUB" ] || { echo "failed to derive public key from private key"; exit 1; }

# apply new config
docker restart "$NAME" >/dev/null
sleep 2
docker ps --format '{{.Names}} {{.Status}}' | grep -q "$NAME" || { echo "container failed to restart"; exit 1; }

SERVER_IP="$(curl -sS -m 10 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
SPX="/$(openssl rand -hex 6)"
SPX_ENC="$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$SPX")"

LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUB}&sid=${SHORT_ID}&spx=${SPX_ENC}&type=tcp&headerType=none#${LABEL}"

[ -f "$DIR/share-link.txt" ] && printf '%s\n' "$LINK" >> "$DIR/share-link.txt"

echo
echo "Added user: $LABEL"
echo
echo "$LINK"
echo
