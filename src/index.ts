import 'dotenv/config';
import express, { type Request, type Response } from 'express';
import { ImapFlow } from 'imapflow';
import nodemailer from 'nodemailer';
import { simpleParser } from 'mailparser';
import { z } from 'zod';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';

const PORT = Number(process.env.PORT ?? 3100);
const MCP_PATH = process.env.MCP_PATH ?? '/migadu';
const MCP_BEARER_TOKEN = process.env.MCP_BEARER_TOKEN?.trim();

function required(name: string): string {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`Missing required environment variable: ${name}`);
  return value;
}

function bool(name: string, fallback: boolean): boolean {
  const value = process.env[name];
  if (value == null) return fallback;
  return ['1', 'true', 'yes', 'on'].includes(value.toLowerCase());
}

function imapClient() {
  return new ImapFlow({
    host: process.env.IMAP_HOST ?? 'imap.migadu.com',
    port: Number(process.env.IMAP_PORT ?? 993),
    secure: bool('IMAP_SECURE', true),
    auth: { user: required('IMAP_USER'), pass: required('IMAP_PASSWORD') },
    logger: false,
  });
}

function smtpTransport() {
  return nodemailer.createTransport({
    host: process.env.SMTP_HOST ?? 'smtp.migadu.com',
    port: Number(process.env.SMTP_PORT ?? 465),
    secure: bool('SMTP_SECURE', true),
    auth: { user: required('SMTP_USER'), pass: required('SMTP_PASSWORD') },
  });
}

function text(data: unknown) {
  return { content: [{ type: 'text' as const, text: JSON.stringify(data, null, 2) }] };
}

async function withMailbox<T>(mailbox: string, fn: (client: ImapFlow) => Promise<T>): Promise<T> {
  const client = imapClient();
  await client.connect();
  try {
    const lock = await client.getMailboxLock(mailbox);
    try {
      return await fn(client);
    } finally {
      lock.release();
    }
  } finally {
    await client.logout().catch(() => undefined);
  }
}

function createServer() {
  const server = new McpServer({ name: 'alazab-migadu-mail', version: '1.0.0' });

  server.tool(
    'mail_list_folders',
    'List folders/mailboxes available in the configured Migadu account.',
    {},
    async () => {
      const client = imapClient();
      await client.connect();
      try {
        const folders = await client.list();
        return text(folders.map((f) => ({ path: f.path, name: f.name, specialUse: f.specialUse ?? null })));
      } finally {
        await client.logout().catch(() => undefined);
      }
    },
  );

  server.tool(
    'mail_search',
    'Search messages in a Migadu mailbox and return matching message metadata. UID values can be passed to mail_get_message.',
    {
      mailbox: z.string().default('INBOX'),
      from: z.string().optional(),
      subject: z.string().optional(),
      text: z.string().optional(),
      since: z.string().optional().describe('ISO date, for example 2026-09-01'),
      before: z.string().optional().describe('ISO date, for example 2026-10-01'),
      limit: z.number().int().min(1).max(100).default(20),
    },
    async ({ mailbox, from, subject, text: bodyText, since, before, limit }) =>
      withMailbox(mailbox, async (client) => {
        const criteria: Record<string, unknown> = {};
        if (from) criteria.from = from;
        if (subject) criteria.subject = subject;
        if (bodyText) criteria.body = bodyText;
        if (since) criteria.since = new Date(since);
        if (before) criteria.before = new Date(before);
        if (Object.keys(criteria).length === 0) criteria.all = true;

        const found = await client.search(criteria);
        const uids = (found || []).slice(-limit).reverse();
        const results: unknown[] = [];
        for (const uid of uids) {
          const msg = await client.fetchOne(uid, { uid: true, envelope: true, flags: true, internalDate: true }, { uid: true });
          if (!msg) continue;
          results.push({
            uid: msg.uid,
            subject: msg.envelope?.subject ?? null,
            from: msg.envelope?.from?.map((a) => ({ name: a.name ?? null, address: a.address ?? null })) ?? [],
            to: msg.envelope?.to?.map((a) => ({ name: a.name ?? null, address: a.address ?? null })) ?? [],
            date: msg.envelope?.date ?? msg.internalDate ?? null,
            messageId: msg.envelope?.messageId ?? null,
            flags: msg.flags ? [...msg.flags] : [],
          });
        }
        return text(results);
      }),
  );

  server.tool(
    'mail_get_message',
    'Read one complete email by IMAP UID, including parsed text/HTML summary and attachment metadata.',
    {
      mailbox: z.string().default('INBOX'),
      uid: z.number().int().positive(),
      includeHtml: z.boolean().default(false),
    },
    async ({ mailbox, uid, includeHtml }) =>
      withMailbox(mailbox, async (client) => {
        const msg = await client.fetchOne(uid, { uid: true, source: true, envelope: true, flags: true, internalDate: true }, { uid: true });
        if (!msg || !msg.source) throw new Error(`Message UID ${uid} not found in ${mailbox}`);
        const parsed = await simpleParser(msg.source);
        return text({
          uid,
          mailbox,
          subject: parsed.subject ?? msg.envelope?.subject ?? null,
          from: parsed.from?.text ?? null,
          to: parsed.to ? (Array.isArray(parsed.to) ? parsed.to.map((v) => v.text).join(', ') : parsed.to.text) : null,
          cc: parsed.cc ? (Array.isArray(parsed.cc) ? parsed.cc.map((v) => v.text).join(', ') : parsed.cc.text) : null,
          date: parsed.date ?? msg.internalDate ?? null,
          messageId: parsed.messageId ?? msg.envelope?.messageId ?? null,
          text: parsed.text ?? '',
          html: includeHtml ? parsed.html || null : undefined,
          attachments: parsed.attachments.map((a, index) => ({
            index,
            filename: a.filename ?? null,
            contentType: a.contentType,
            size: a.size,
            contentId: a.cid ?? null,
          })),
          flags: msg.flags ? [...msg.flags] : [],
        });
      }),
  );

  server.tool(
    'mail_send',
    'Send an email through Migadu SMTP. Disabled unless MAIL_ALLOW_SEND=true.',
    {
      to: z.string().min(3),
      subject: z.string().min(1),
      text: z.string().min(1),
      cc: z.string().optional(),
      bcc: z.string().optional(),
      replyTo: z.string().optional(),
    },
    async ({ to, subject, text: body, cc, bcc, replyTo }) => {
      if (!bool('MAIL_ALLOW_SEND', false)) throw new Error('Sending is disabled. Set MAIL_ALLOW_SEND=true after read-only validation.');
      const transport = smtpTransport();
      const result = await transport.sendMail({
        from: process.env.MAIL_FROM ?? required('SMTP_USER'),
        to,
        cc,
        bcc,
        replyTo,
        subject,
        text: body,
      });
      return text({ accepted: result.accepted, rejected: result.rejected, messageId: result.messageId });
    },
  );

  return server;
}

function authorized(req: Request): boolean {
  if (!MCP_BEARER_TOKEN) return true;
  return req.header('authorization') === `Bearer ${MCP_BEARER_TOKEN}`;
}

const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '2mb' }));

app.get('/health', (_req, res) => {
  res.json({ ok: true, service: 'alazab-migadu-mcp', mcpPath: MCP_PATH });
});

app.all(MCP_PATH, async (req: Request, res: Response) => {
  if (!authorized(req)) {
    res.status(401).set('WWW-Authenticate', 'Bearer').json({ error: 'unauthorized' });
    return;
  }

  if (!['POST', 'GET', 'DELETE'].includes(req.method)) {
    res.sendStatus(405);
    return;
  }

  const server = createServer();
  const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined, enableJsonResponse: true });
  res.on('close', () => {
    void transport.close();
    void server.close();
  });

  try {
    await server.connect(transport);
    await transport.handleRequest(req, res, req.body);
  } catch (error) {
    console.error(error);
    if (!res.headersSent) res.status(500).json({ error: 'MCP request failed' });
  }
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`Alazab Migadu MCP listening on :${PORT}${MCP_PATH}`);
});
