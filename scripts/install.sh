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
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl nginx certbot python3-certbot-nginx
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker nginx

echo "[2/7] Preparing configuration..."
if [[ ! -f .env ]]; then
  cp .env.example .env
fi
chmod 600 .env

# Generate a strong MCP token if placeholder/empty.
CURRENT_TOKEN="$(grep -E '^MCP_AUTH_TOKEN=' .env | cut -d= -f2- || true)"
if [[ -z "$CURRENT_TOKEN" || "$CURRENT_TOKEN" == "change-me" ]]; then
  TOKEN="$(openssl rand -hex 32)"
  if grep -q '^MCP_AUTH_TOKEN=' .env; then
    sed -i "s|^MCP_AUTH_TOKEN=.*|MCP_AUTH_TOKEN=$TOKEN|" .env
  else
    printf '\nMCP_AUTH_TOKEN=%s\n' "$TOKEN" >> .env
  fi
fi

# Force production endpoint settings.
sed -i 's|^PORT=.*|PORT=3100|' .env
sed -i 's|^MCP_PATH=.*|MCP_PATH=/migadu|' .env

echo "[3/7] Checking required Migadu credentials..."
IMAP_USER="$(grep -E '^IMAP_USER=' .env | cut -d= -f2- || true)"
IMAP_PASSWORD="$(grep -E '^IMAP_PASSWORD=' .env | cut -d= -f2- || true)"
if [[ -z "$IMAP_USER" || "$IMAP_USER" == "mailbox@example.com" || -z "$IMAP_PASSWORD" || "$IMAP_PASSWORD" == "change-me" ]]; then
  echo
  echo "ACTION REQUIRED: edit $APP_DIR/.env and set IMAP_USER/IMAP_PASSWORD and SMTP_USER/SMTP_PASSWORD."
  echo "Then run this installer again. No credentials are stored in Git."
  exit 2
fi

echo "[4/7] Building and starting Migadu MCP..."
docker compose up -d --build --remove-orphans

for i in {1..30}; do
  if curl -fsS http://127.0.0.1:3100/health >/dev/null 2>&1; then break; fi
  sleep 2
done
curl -fsS http://127.0.0.1:3100/health >/dev/null

echo "[5/7] Configuring Nginx..."
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

    location / {
        return 404;
    }
}
NGINX
ln -sfn /etc/nginx/sites-available/mcp.alazab.com /etc/nginx/sites-enabled/mcp.alazab.com
nginx -t
systemctl reload nginx

echo "[6/7] Issuing/renewing Let's Encrypt SSL..."
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --redirect
systemctl enable --now certbot.timer 2>/dev/null || true

echo "[7/7] Final verification..."
curl -fsS "https://$DOMAIN/health"
echo
TOKEN="$(grep -E '^MCP_AUTH_TOKEN=' .env | cut -d= -f2-)"
echo "============================================================"
echo "MIGADU MCP DEPLOYED"
echo "Endpoint: https://$DOMAIN$APP_PATH"
echo "Health:   https://$DOMAIN/health"
echo "Auth:     Bearer token stored only in $APP_DIR/.env"
echo "Sending:  disabled by default (MAIL_ALLOW_SEND=false)"
echo "============================================================"
echo "To display the token locally: grep '^MCP_AUTH_TOKEN=' $APP_DIR/.env"
