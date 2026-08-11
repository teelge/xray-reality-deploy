# XRay Reality Server — one-command deployment

Self-deploying [XRay](https://github.com/XTLS/Xray-core) **VLESS + Reality** proxy server in Docker. Designed to bypass DPI-based censorship (Iran, etc.) by making proxy traffic indistinguishable from browsing a popular local website. No TLS certificate needed.

## Deploy (fresh Ubuntu/Debian server, as root)

```bash
curl -fsSL https://raw.githubusercontent.com/teelge/xray-reality-deploy/main/deploy.sh | bash
```

Or clone and run:

```bash
git clone https://github.com/teelge/xray-reality-deploy.git
cd xray-reality-deploy
sudo bash deploy.sh
```

The script prints a `vless://...` share link at the end — paste it into **v2rayNG** (Android), **Happ/Streisand/FoXray** (iOS), or **v2rayA**.

## Options (environment variables)

| Variable   | Default            | Meaning                          |
|------------|--------------------|----------------------------------|
| `DOMAIN`   | `www.digikala.com` | Disguise SNI (must support TLS 1.3). Iranian options: `snapp.ir`, `www.aparat.com`, `www.varzesh3.com` |
| `PORT`     | `443`              | Listening port                   |
| `XRAY_TAG` | `25.12.8`          | Xray docker image tag            |
| `DIR`      | `/opt/xray-reality`| Install directory                |
| `NAME`     | `xray-reality`     | Container name                   |

Example with a different disguise and port:

```bash
DOMAIN=snapp.ir PORT=8443 bash deploy.sh
```

## Management

```bash
cd /opt/xray-reality
docker compose restart       # restart
docker logs xray-reality     # view connections
docker compose down          # stop
cat share-link.txt           # show the share link again
```

## Security notes

- **Keys are generated fresh on each deploy** — nothing secret is stored in this repo.
- `config.json` and `share-link.txt` are chmod 600 on the server. Anyone with the link gets full tunnel access — share it only over secure channels.
- To revoke access, use `xray-users revoke <label>` (or redeploy to regenerate all keys).

## Known pitfalls (learned the hard way)

- **Client/server version mismatch**: a newer Xray server (26.x) may reject an older client's Reality handshake (`REALITY: processed invalid connection ... authentication failed`). This repo pins `25.12.8` (matches v2rayNG's core). If your client app uses a different core version, deploy with `XRAY_TAG=<version>`.
- Container logs print in Asia/Shanghai timezone — timestamps look 8h off but the clock is fine.
- Debug handshakes: set `"loglevel": "debug"` and `"show": true` in `realitySettings`, then `docker compose up -d`.

## Managing users

The `xray-users` CLI is installed automatically by `deploy.sh`.

**Interactive mode** (menu, numbered user picker, confirmations):

```bash
xray-users
```

```
  1) Add a new user
  2) List users
  3) Get share link
  4) Revoke a user
  5) Quit
```

**Non-interactive** (for scripting):

```bash
xray-users add myfriend          # create user, prints share link
xray-users add                   # auto-labeled user
xray-users list                  # show all users + UUIDs
xray-users link myfriend         # print someone's share link again
xray-users revoke myfriend       # remove user (works by label or UUID)
```

- Revoking is immediate — the container restarts and the old link stops working.
- All users share the disguise/keypair; each has a unique UUID.
- If deployed before this CLI existed: `cp xray-users /usr/local/bin/ && chmod +x /usr/local/bin/xray-users`
