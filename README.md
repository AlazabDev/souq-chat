# Alazab Migadu MCP

Migadu IMAP/SMTP bridge exposed as MCP Streamable HTTP.

**Production endpoint:** `https://mcp.alazab.com/migadu`

## Production deployment

The server only needs the repository clone and one installer command:

```bash
git clone https://github.com/AlazabDev/souq-chat.git
cd souq-chat
sudo bash scripts/install.sh
```

On the first run the installer asks only for the Migadu mailbox and mailbox/app password. The password is stored in the server-local `.env` with mode `600`; it is never committed to Git.

The installer automatically:

- installs Docker when missing;
- installs Nginx and Certbot;
- creates a random MCP Bearer token;
- builds and starts the Docker service;
- binds the application only to `127.0.0.1:3100`;
- configures Nginx for `mcp.alazab.com/migadu`;
- obtains and configures Let's Encrypt SSL;
- enables certificate renewal;
- verifies the HTTPS health endpoint.

At completion it prints the production endpoint and the local command for reading the generated Bearer token.

## Safety default

`MAIL_ALLOW_SEND=false` is the production default. IMAP read/search can be tested before SMTP sending is enabled.

## MCP tools

- `mail_list_folders`
- `mail_search`
- `mail_get_message`
- `mail_send`

## Update deployment

```bash
cd souq-chat
git pull
sudo bash scripts/install.sh
```
