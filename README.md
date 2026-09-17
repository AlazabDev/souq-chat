# Alazab Migadu MCP

Production-oriented MCP bridge for the Alazab Migadu mailbox.

Target public endpoint: `https://mcp.alazab.com/migadu`

## Transport

- MCP: Streamable HTTP
- Mail read/search: IMAP over TLS
- Mail send/reply: SMTP over TLS

## Security

Secrets are never committed. Copy `.env.example` to `.env` on the deployment server and fill credentials there.

## Run

```bash
npm ci
npm run build
npm start
```

Or with Docker:

```bash
docker compose up -d --build
```

The application listens on `PORT` (default `3100`). Your reverse proxy should route `/migadu` on `mcp.alazab.com` to this service.

## Initial MCP tools

- `mail_list_folders`
- `mail_search`
- `mail_get_message`
- `mail_send`

Write operations can be disabled with `MAIL_ALLOW_SEND=false`.
