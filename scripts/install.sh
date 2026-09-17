#!/usr/bin/env bash
set -Eeuo pipefail

DOMAIN="${DOMAIN:-mcp.alazab.com}"
APP_PATH="${APP_PATH:-/migadu}"
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EMAIL="${LETSENCRYPT_EMAIL:-admin@alazab.com}"

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo: sudo bash scripts/install.sh"
  exit 1
fi
cd "$APP_DIR"

echo "[1/7] Installing Docker, Nginx and Certbot..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl openssl nginx certbot python3-certbot-nginx
if ! command -v docker >/dev/null 2>&1; then curl -fsSL https://get.docker.com | sh; fi
systemctl enable --now docker nginx

echo "[2/7] Preparing secure configuration..."
if [[ ! -f .env ]]; then cp .env.example .env; fi
chmod 600 .env
set_env() {
  local key="$1" value="$2"
  if grep -q "^${key}=" .env; then
    sed -i "s|^${key}=.*|${key}=${value}|" .env
  else
    printf '%s=%s\n' "$key" "$value" >> .env
  fi
}
set_env PORT 3100
set_env MCP_PATH /migadu
TOKEN="$(grep -E '^MCP_BEARER_TOKEN=' .env | cut -d= -f2- || true)"
if [[ -z "$TOKEN" || "$TOKEN" == "replace-with-a-long-random-secret" || "$TOKEN" == "change-me" ]]; then
  set_env MCP_BEARER_TOKEN "$(openssl rand -hex 32)"
fi

IMAP_USER="$(grep -E '^IMAP_USER=' .env | cut -d= -f2- || true)"
IMAP_PASSWORD="$(grep -E '^IMAP_PASSWORD=' .env | cut -d= -f2- || true)"
if [[ -z "$IMAP_USER" || "$IMAP_USER" == "mailbox@example.com" || -z "$IMAP_PASSWORD" || "$IMAP_PASSWORD" == "change-me" ]]; then
  echo
  echo "Migadu credentials are required once. They will be written ONLY to local .env."
  read -rp "Migadu mailbox (full email): " MAILBOX
  read -rsp "Migadu mailbox/app password: " MAILPASS; echo
  [[ -n "$MAILBOX" && -n "$MAILPASS" ]] || { echo "Mailbox/password cannot be empty."; exit 2; }
  set_env IMAP_USER "$MAILBOX"
  set_env IMAP_PASSWORD "$MAILPASS"
  set_env SMTP_USER "$MAILBOX"
  set_env SMTP_PASSWORD "$MAILPASS"
  set_env MAIL_FROM "$MAILBOX"
fi

echo "[3/7] Building and starting Migadu MCP..."
docker compose up -d --build --remove-orphans
for i in {1..30}; do
  if curl -fsS http://127.0.0.1:3100/health >/dev/null 2>&1; then break; fi
  sleep 2
done
curl -fsS http://127.0.0.1:3100/health >/dev/null

echo "[4/7] Configuring Nginx..."
cat > /etc/nginx/sites-available/mcp.alazab.com <<'NGINX'
server {
    listen 80;
    listen [::]:80;
    server_name mcp.alazab.com;

    location = /health {
        proxy_pass http://127.0.0.1:3100/health;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /migadu {
        proxy_pass http://127.0.0.1:3100;
        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection "";
    }

    location / { return 404; }
}
NGINX
ln -sfn /etc/nginx/sites-available/mcp.alazab.com /etc/nginx/sites-enabled/mcp.alazab.com
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx

echo "[5/7] Issuing Let's Encrypt SSL..."
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --redirect --keep-until-expiring
systemctl enable --now certbot.timer 2>/dev/null || true

echo "[6/7] Verifying HTTPS..."
curl -fsS "https://$DOMAIN/health"
echo

echo "[7/7] Deployment complete."
echo "============================================================"
echo "Endpoint: https://$DOMAIN$APP_PATH"
echo "Health:   https://$DOMAIN/health"
echo "Auth:     Bearer token stored only in $APP_DIR/.env"
echo "Sending:  disabled by default (MAIL_ALLOW_SEND=false)"
echo "Token:    grep '^MCP_BEARER_TOKEN=' $APP_DIR/.env"
echo "============================================================"
