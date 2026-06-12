import { Message, Attachment, Embed, StickerFormatType } from 'discord.js';
import { pipeline } from 'stream/promises';
import { createWriteStream } from 'fs';
import { mkdir } from 'fs/promises';
import { Readable } from 'stream';
import * as path from 'path';
import * as db from './db.js';
import * as spawner from './spawner.js';
import * as fmt from './discord-format.js';

const MAX_ATTACHMENT_SIZE = 25 * 1024 * 1024; // 25 MB

// Message buffer: while a project is busy, incoming messages accumulate here
const messageBuffer = new Map<string, Message[]>();

// Processing lock: prevents race conditions between finalize awaits and new messages.
// Set synchronously BEFORE any awaits in handleMessage, cleared AFTER all
// processing (including drain) completes. Checked alongside spawner.isRunning().
const processing = new Set<string>();

export function getBufferedCount(projectPath: string): number {
  return messageBuffer.get(projectPath)?.length ?? 0;
}

export function clearBuffers(): void {
  messageBuffer.clear();
  processing.clear();
}

interface SavedAttachment {
  name: string;
  filePath: string;
  contentType: string | null;
  size: number;
}

interface StickerContext {
  name: string;
  description: string | null;
  filePath: string | null;
  format: string;
}

interface GifContext {
  url: string;
  description: string;
}

function getAuthorName(message: Message): string {
  return message.member?.displayName
    || message.author.displayName
    || message.author.username;
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes}B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(0)}KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)}MB`;
}

/**
 * Download Discord attachments to the project's .attachments/ directory.
 */
export async function downloadAttachments(
  attachments: Message['attachments'],
  projectPath: string,
): Promise<SavedAttachment[]> {
  if (!attachments.size) return [];

  const dir = path.join(projectPath, '.attachments');
  await mkdir(dir, { recursive: true });

  const saved: SavedAttachment[] = [];
  for (const [, att] of attachments) {
    if (att.size > MAX_ATTACHMENT_SIZE) {
      console.log(
        `[${new Date().toISOString()}] Skipping attachment ${att.name} (${formatBytes(att.size)} > ${formatBytes(MAX_ATTACHMENT_SIZE)})`,
      );
      continue;
    }

    const fileName = `${Date.now()}-${att.name}`;
    const filePath = path.join(dir, fileName);

    try {
      const response = await fetch(att.url);
      if (!response.ok || !response.body) {
        throw new Error(`HTTP ${response.status}`);
      }
      const readable = Readable.fromWeb(response.body as any);
      await pipeline(readable, createWriteStream(filePath));

      saved.push({
        name: att.name,
        filePath,
        contentType: att.contentType,
        size: att.size,
      });
    } catch (err) {
      console.error(
        `[${new Date().toISOString()}] Failed to download attachment ${att.name}:`,
        err,
      );
    }
  }

  return saved;
}

/**
 * Download sticker images and extract metadata.
 * Lottie stickers are text-only (JSON format, not viewable as image).
 */
export async function downloadStickers(
  stickers: Message['stickers'],
  projectPath: string,
): Promise<StickerContext[]> {
  if (!stickers?.size) return [];

  const dir = path.join(projectPath, '.attachments');
  await mkdir(dir, { recursive: true });

  const results: StickerContext[] = [];

  for (const [, sticker] of stickers) {
    const formatName = StickerFormatType[sticker.format] || 'Unknown';
    const isLottie = sticker.format === StickerFormatType.Lottie;

    let filePath: string | null = null;

    if (!isLottie) {
      try {
        const url = sticker.url;
        const ext = sticker.format === StickerFormatType.GIF ? 'gif' : 'png';
        const fileName = `${Date.now()}-sticker-${sticker.name}.${ext}`;
        filePath = path.join(dir, fileName);

        const response = await fetch(url);
        if (!response.ok || !response.body) {
          throw new Error(`HTTP ${response.status}`);
        }
        const readable = Readable.fromWeb(response.body as any);
        await pipeline(readable, createWriteStream(filePath));
      } catch (err) {
        console.error(
          `[${new Date().toISOString()}] Failed to download sticker ${sticker.name}:`,
          err,
        );
        filePath = null;
      }
    }

    results.push({
      name: sticker.name,
      description: sticker.description,
      filePath,
      format: formatName,
    });
  }

  return results;
}

/**
 * Extract descriptive context from GIF embeds (Tenor/Giphy via Discord GIF picker).
 */
export function extractGifContext(message: Message): GifContext[] {
  const results: GifContext[] = [];

  for (const embed of message.embeds) {
    if (embed.data.type !== 'gifv') continue;

    const url = embed.url || '';
    const description = extractGifDescription(url, embed);

    if (description) {
      results.push({ url, description });
    }
  }

  return results;
}

function extractGifDescription(url: string, embed: Embed): string {
  // Try Tenor slug: /view/{slug}-{id}
  const tenorMatch = url.match(/tenor\.com\/view\/([\w-]+?)(?:-\d+)?$/);
  if (tenorMatch) {
    return tenorMatch[1].replace(/-/g, ' ');
  }

  // Try Giphy slug: /gifs/{slug}-{id}
  const giphyMatch = url.match(/giphy\.com\/gifs\/([\w-]+?)(?:-\w+)?$/);
  if (giphyMatch) {
    return giphyMatch[1].replace(/-/g, ' ');
  }

  // Fallback to embed metadata
  if (embed.description) return embed.description;
  if (embed.title) return embed.title;
  if (embed.provider?.name) return `GIF from ${embed.provider.name}`;

  return 'GIF';
}

function formatStickerText(sticker: { name: string; description?: string | null }): string {
  return `[Sticker: "${sticker.name}"${sticker.description ? ` — ${sticker.description}` : ''}]`;
}

/**
 * Build prompt for a single message including reply context, forwards, and attachments.
 */
export async function buildPrompt(
  message: Message,
  savedAttachments: SavedAttachment[] = [],
  includeAuthor: boolean = true,
  stickerContexts: StickerContext[] = [],
  gifContexts: GifContext[] = [],
): Promise<string> {
  const parts: string[] = [];

  // Handle reply — fetch the referenced message and include as context
  if (message.reference?.messageId) {
    try {
      const ref = await message.channel.messages.fetch(
        message.reference.messageId,
      );
      const author = ref.author?.displayName || ref.author?.username || 'Unknown';
      let refContent = ref.content || '';

      // Include embed text if the referenced message has embeds
      if (ref.embeds.length > 0) {
        const embedTexts = ref.embeds
          .map((e) => [e.title, e.description].filter(Boolean).join(': '))
          .filter(Boolean);
        if (embedTexts.length > 0) {
          refContent += (refContent ? '\n' : '') + embedTexts.join('\n');
        }
      }

      // Include sticker context from referenced message
      if (ref.stickers?.size) {
        const stickerTexts = [...ref.stickers.values()]
          .map(formatStickerText)
          .join(', ');
        refContent += (refContent ? '\n' : '') + stickerTexts;
      }

      // Include GIF context from referenced message embeds
      const refGifs = ref.embeds
        .filter((e) => e.data?.type === 'gifv')
        .map((e) => `[GIF: ${extractGifDescription(e.url || '', e)}]`);
      if (refGifs.length) {
        refContent += (refContent ? '\n' : '') + refGifs.join(', ');
      }

      if (refContent) {
        parts.push(
          `[Replying to message from ${author}]\n${refContent}\n\n[Your message]`,
        );
      }
    } catch {
      // Can't fetch referenced message — proceed without context
    }
  }

  // Handle forwarded messages (Discord message snapshots, discord.js v14.16+)
  if (message.messageSnapshots?.size) {
    for (const [, snap] of message.messageSnapshots) {
      const fwdContent = snap.content || '';
      const embedTexts = (snap.embeds || [])
        .map((e) => [e.title, e.description].filter(Boolean).join(': '))
        .filter(Boolean);
      const stickerTexts = snap.stickers?.size
        ? [...snap.stickers.values()].map(formatStickerText)
        : [];
      const combined = [fwdContent, ...embedTexts, ...stickerTexts].filter(Boolean).join('\n');
      if (combined) {
        parts.push(`[Forwarded message]\n${combined}\n`);
      }
    }
  }

  // Include attachment info
  if (savedAttachments.length > 0) {
    const fileList = savedAttachments
      .map((f) => `- ${f.filePath} (${f.name}, ${f.contentType || 'unknown'}, ${formatBytes(f.size)})`)
      .join('\n');
    parts.push(`[Attached files saved to disk]\n${fileList}\n`);
  }

  // Include sticker context
  if (stickerContexts.length > 0) {
    const stickerLines = stickerContexts.map((s) => {
      const parts = [`"${s.name}"`];
      if (s.description) parts.push(`(${s.description})`);
      if (s.filePath) {
        parts.push(`— image saved to ${s.filePath} (use Read tool to see it)`);
      } else {
        parts.push(`— ${s.format} format, no image available`);
      }
      return `- ${parts.join(' ')}`;
    }).join('\n');
    parts.push(`[Sticker${stickerContexts.length > 1 ? 's' : ''} sent]\n${stickerLines}\n`);
  }

  // Include GIF context from embeds
  if (gifContexts.length > 0) {
    const gifLines = gifContexts
      .map((g) => `- ${g.description} (${g.url})`)
      .join('\n');
    parts.push(`[GIF${gifContexts.length > 1 ? 's' : ''} sent]\n${gifLines}\n`);
  }

  if (includeAuthor) {
    parts.push(`[${getAuthorName(message)}] ${message.content}`);
  } else {
    parts.push(message.content);
  }
  return parts.join('\n');
}

/**
 * Build a combined prompt from multiple buffered messages.
 */
async function buildBatchPrompt(
  messages: Message[],
  projectPath: string,
): Promise<string> {
  const parts: string[] = [];

  parts.push(
    `[While you were busy, the user sent ${messages.length} more message${messages.length > 1 ? 's' : ''}. Process them all.]`,
  );

  for (let i = 0; i < messages.length; i++) {
    const msg = messages[i];
    const savedAtts = await downloadAttachments(msg.attachments, projectPath);
    const stickerCtxs = await downloadStickers(msg.stickers, projectPath);
    const gifCtxs = extractGifContext(msg);
    const authorName = getAuthorName(msg);

    if (messages.length > 1) {
      const msgPrompt = await buildPrompt(msg, savedAtts, false, stickerCtxs, gifCtxs);
      parts.push(`[Message ${i + 1}/${messages.length} from ${authorName}]\n${msgPrompt}`);
    } else {
      const msgPrompt = await buildPrompt(msg, savedAtts, true, stickerCtxs, gifCtxs);
      parts.push(msgPrompt);
    }
  }

  return parts.join('\n\n');
}

// ── Entry point ──────────────────────────────────────────────

export async function handleMessage(message: Message): Promise<void> {
  const project = db.getProjectByChannelId(message.channel.id);
  if (!project) return;

  const pp = project.project_path;

  if (processing.has(pp) || spawner.isRunning(pp)) {
    // Buffer the message — it will be processed after the current task
    const buf = messageBuffer.get(pp) || [];
    buf.push(message);
    messageBuffer.set(pp, buf);
    await message.react('\uD83D\uDCCB').catch(() => {}); // 📋 queued
    return;
  }

  // Acquire processing lock synchronously — before any awaits
  processing.add(pp);
  try {
    // Flush buffer: if messages accumulated while busy, combine with current
    const buffered = messageBuffer.get(pp);
    if (buffered && buffered.length > 0) {
      messageBuffer.delete(pp);
      buffered.push(message);
      console.log(
        `[${new Date().toISOString()}] Flushing ${buffered.length - 1} buffered + 1 new message for ${project.name}`,
      );
      await processBatch(buffered, project);
      return;
    }

    // Process single message
    const session = db.getOrCreateSession(project.id);
    db.updateSessionStatus(session.id, 'running');

    await message.react('\u23F3').catch(() => {}); // ⏳ hourglass
    if ('sendTyping' in message.channel) {
      await message.channel.sendTyping().catch(() => {});
    }

    const savedAttachments = await downloadAttachments(
      message.attachments,
      project.project_path,
    );
    const stickerContexts = await downloadStickers(
      message.stickers,
      project.project_path,
    );
    const gifContexts = extractGifContext(message);
    const prompt = await buildPrompt(message, savedAttachments, true, stickerContexts, gifContexts);

    const result = await runWithRetry(prompt, project, session, 'user');
    await finalize(message, session, result, project.project_path);

    // Drain any messages that arrived while we were busy
    await drainBuffer(project);
  } finally {
    processing.delete(pp);
  }
}

// ── Process batch of messages ────────────────────────────────

async function processBatch(
  messages: Message[],
  project: db.Project,
): Promise<void> {
  const lastMessage = messages[messages.length - 1];
  const session = db.getOrCreateSession(project.id);
  db.updateSessionStatus(session.id, 'running');

  await lastMessage.react('\u23F3').catch(() => {});
  if ('sendTyping' in lastMessage.channel) {
    await lastMessage.channel.sendTyping().catch(() => {});
  }

  const prompt = await buildBatchPrompt(messages, project.project_path);
  const result = await runWithRetry(prompt, project, session, 'user');
  await finalizeBatch(messages, session, result, project.project_path);

  // Drain any messages that arrived during this batch
  await drainBuffer(project);
}

// ── Drain buffered messages ──────────────────────────────────

async function drainBuffer(project: db.Project): Promise<void> {
  const buffered = messageBuffer.get(project.project_path);
  if (!buffered || buffered.length === 0) return;

  messageBuffer.delete(project.project_path);

  console.log(
    `[${new Date().toISOString()}] Draining ${buffered.length} buffered message(s) for ${project.name}`,
  );

  await processBatch(buffered, project);
}

// ── Auto-review trigger (called by watcher when a new proposal arrives) ───

export async function handleAutoReview(
  project: db.Project,
  proposalFile: string,
): Promise<spawner.SpawnResult> {
  const pp = project.project_path;

  // Wait until any user-message processing finishes. Poll cheaply; auto-review is not urgent.
  while (processing.has(pp) || spawner.isRunning(pp)) {
    await new Promise((r) => setTimeout(r, 500));
  }

  processing.add(pp);
  try {
    const session = db.getOrCreateSession(project.id);
    db.updateSessionStatus(session.id, 'running');

    const prompt = [
      `[auto-review trigger] New proposal arrived in this vault: \`proposals/${proposalFile}\`.`,
      ``,
      `Read its frontmatter (target_path, contributed_by, contribution_reason) and body.`,
      `If target_path already exists, read it and show a brief diff preview (what the proposal adds/changes).`,
      ``,
      `Present concisely in one message:`,
      `1. From whom, where it wants to land, why.`,
      `2. TL;DR of the proposal.`,
      `3. Similarity context (use search_notes or the decision reason in the proposal frontmatter).`,
      `4. Options: accept / merge / edit / reject.`,
      ``,
      `Then STOP and wait for user's decision. Do NOT integrate yet.`,
    ].join('\n');

    const result = await runWithRetry(prompt, project, session, 'auto_review');
    updateSession(session, result);
    return result;
  } finally {
    processing.delete(pp);
  }
}

// ── Nightly reconcile (called by the reconcile scheduler) ────

export async function handleReconcile(
  project: db.Project,
): Promise<spawner.SpawnResult> {
  const pp = project.project_path;

  // Wait until any user-message processing finishes. Poll cheaply; reconcile is not urgent.
  while (processing.has(pp) || spawner.isRunning(pp)) {
    await new Promise((r) => setTimeout(r, 500));
  }

  processing.add(pp);
  try {
    const session = db.getOrCreateSession(project.id);
    db.updateSessionStatus(session.id, 'running');

    const result = await runWithRetry('/reconcile', project, session, 'reconcile');
    updateSession(session, result);

    if (result.success) {
      // Close the session: the next message starts fresh, with the distilled
      // memory files in context via the project CLAUDE.md imports.
      db.updateSessionClaudeId(session.id, null);
    }

    return result;
  } finally {
    processing.delete(pp);
  }
}

// ── Spawn with session-error retry ───────────────────────────

async function runWithRetry(
  prompt: string,
  project: db.Project,
  session: db.Session,
  kind: string,
): Promise<spawner.SpawnResult> {
  const result = await spawner.spawnClaude({
    prompt,
    projectPath: project.project_path,
    claudeSessionId: session.claude_session_id,
    skipPermissions: project.skip_permissions,
    identity: project.identity,
    kind,
  });
  logSpawn(project.id, result, kind);

  if (
    !result.success &&
    result.error &&
    /session|expired|not found/i.test(result.error)
  ) {
    console.log(
      `[${new Date().toISOString()}] Session error for ${project.name}, retrying with fresh session`,
    );
    db.updateSessionClaudeId(session.id, null);

    const retry = await spawner.spawnClaude({
      prompt,
      projectPath: project.project_path,
      claudeSessionId: null,
      skipPermissions: project.skip_permissions,
      identity: project.identity,
      kind,
    });
    logSpawn(project.id, retry, kind);
    return retry;
  }

  return result;
}

function logSpawn(
  projectId: string,
  result: spawner.SpawnResult,
  kind: string,
): void {
  try {
    db.insertSpawnLog({
      projectId,
      claudeSessionId: result.claudeSessionId || null,
      kind,
      resumed: result.resumed,
      durationMs: result.durationMs,
      peakRssKb: result.peakRssKb,
      success: result.success,
      costUsd: result.costUsd ? Number(result.costUsd) : null,
    });
  } catch (err) {
    console.error(
      `[${new Date().toISOString()}] Failed to write spawn_log for ${projectId}:`,
      err,
    );
  }
}

// ── Finalize: single message ─────────────────────────────────

async function finalize(
  message: Message,
  session: db.Session,
  result: spawner.SpawnResult,
  projectPath: string,
): Promise<void> {
  updateSession(session, result);

  if (result.success) {
    const formatted = fmt.formatResult(result.result, result.costUsd);
    await replyWithAttachments(message, formatted, projectPath);
  } else {
    await message.reply(
      fmt.formatError(result.error || 'Unknown error'),
    );
  }

  await message.reactions.cache
    .get('\u23F3')
    ?.users.remove(message.client.user!.id)
    .catch(() => {});
  await message
    .react(result.success ? '\u2705' : '\u274C')
    .catch(() => {});
}

// ── Finalize: batch of buffered messages ─────────────────────

async function finalizeBatch(
  messages: Message[],
  session: db.Session,
  result: spawner.SpawnResult,
  projectPath: string,
): Promise<void> {
  updateSession(session, result);

  const lastMessage = messages[messages.length - 1];

  // Reply to the last message
  if (result.success) {
    const formatted = fmt.formatResult(result.result, result.costUsd);
    await replyWithAttachments(lastMessage, formatted, projectPath);
  } else {
    await lastMessage.reply(
      fmt.formatError(result.error || 'Unknown error'),
    );
  }

  // Update reactions on all buffered messages: 📋 → ✅/❌
  const emoji = result.success ? '\u2705' : '\u274C';
  for (const msg of messages) {
    await msg.reactions.cache
      .get('\uD83D\uDCCB')
      ?.users.remove(msg.client.user!.id)
      .catch(() => {});
    await msg.reactions.cache
      .get('\u23F3')
      ?.users.remove(msg.client.user!.id)
      .catch(() => {});
    await msg.react(emoji).catch(() => {});
  }
}

// ── Reply with outgoing attachments ──────────────────────────

async function replyWithAttachments(
  message: Message,
  formatted: string,
  projectPath: string,
): Promise<void> {
  const { content, files } = fmt.extractAttachments(formatted, projectPath);

  if (!content && files.length === 0) {
    await message.reply(fmt.formatError('Empty response'));
    return;
  }

  // Fast path: no outgoing files — preserve legacy string-payload behaviour.
  if (files.length === 0) {
    for (const chunk of fmt.splitMessage(content)) {
      await message.reply(chunk);
    }
    return;
  }

  // Files go with the last chunk (or stand alone if content is empty).
  const chunks = content ? fmt.splitMessage(content) : [];
  for (let i = 0; i < chunks.length - 1; i++) {
    await message.reply(chunks[i]);
  }
  const lastContent = chunks.length > 0 ? chunks[chunks.length - 1] : '';
  const payload: { content?: string; files: string[] } = { files };
  if (lastContent) payload.content = lastContent;
  await message.reply(payload as any);
}

// ── Helpers ──────────────────────────────────────────────────

function updateSession(
  session: db.Session,
  result: spawner.SpawnResult,
): void {
  if (result.claudeSessionId) {
    db.updateSessionClaudeId(session.id, result.claudeSessionId);
  }
  db.updateSessionStatus(
    session.id,
    result.success ? 'idle' : 'error',
  );
}
