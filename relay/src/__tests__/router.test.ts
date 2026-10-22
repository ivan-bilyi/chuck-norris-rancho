import { describe, it, expect, vi, beforeEach } from 'vitest';
import { Readable } from 'stream';

vi.mock('../db.js');
vi.mock('../spawner.js');
vi.mock('../discord-format.js');
vi.mock('fs/promises', () => ({
  mkdir: vi.fn().mockResolvedValue(undefined),
}));
vi.mock('fs', () => ({
  createWriteStream: vi.fn().mockReturnValue({
    on: vi.fn(),
    once: vi.fn(),
    emit: vi.fn(),
    write: vi.fn(),
    end: vi.fn(),
    destroy: vi.fn(),
  }),
}));
vi.mock('stream/promises', () => ({
  pipeline: vi.fn().mockResolvedValue(undefined),
}));

import * as db from '../db.js';
import * as spawner from '../spawner.js';
import * as fmt from '../discord-format.js';
import { handleMessage, downloadAttachments, downloadStickers, extractGifContext, getBufferedCount, clearBuffers } from '../router.js';

function createFakeStickers(
  items: Array<{ id: string; name: string; description: string | null; format: number; url: string }> = [],
) {
  const entries = items.map((item) => [item.id, item] as const);
  return new Map(entries);
}

function createFakeAttachments(
  items: Array<{ name: string; url: string; size: number; contentType: string | null }> = [],
) {
  const entries = items.map((item, i) => [`att-${i}`, { id: `att-${i}`, ...item }] as const);
  return new Map(entries);
}

function createFakeMessage(overrides: Record<string, unknown> = {}) {
  return {
    content: 'do something',
    channel: {
      id: 'ch-1',
      messages: {
        fetch: vi.fn(),
      },
      sendTyping: vi.fn().mockResolvedValue(undefined),
    },
    author: { tag: 'User#1234', username: 'testuser', displayName: 'TestUser' },
    member: { displayName: 'TestUser' },
    reference: null,
    messageSnapshots: null,
    attachments: createFakeAttachments(),
    stickers: new Map(),
    embeds: [],
    reply: vi.fn().mockResolvedValue(undefined),
    react: vi.fn().mockResolvedValue(undefined),
    reactions: {
      cache: {
        get: vi.fn().mockReturnValue({
          users: {
            remove: vi.fn().mockResolvedValue(undefined),
          },
        }),
      },
    },
    client: { user: { id: 'bot-id' } },
    ...overrides,
  } as any;
}

const fakeProject = {
  id: 'proj-1',
  discord_channel_id: 'ch-1',
  project_path: '/tmp/proj',
  name: 'test',
  skip_permissions: true,
  created_at: '',
};

const fakeSession = {
  id: 'sess-1',
  project_id: 'proj-1',
  claude_session_id: 'claude-1',
  status: 'idle' as const,
  last_active: null,
  created_at: '',
};

const successResult: spawner.SpawnResult = {
  success: true,
  result: 'Done!',
  claudeSessionId: 'claude-2',
  costUsd: '0.05',
  peakRssKb: 450_000,
  durationMs: 1234,
  resumed: true,
};

const errorResult: spawner.SpawnResult = {
  success: false,
  result: '',
  claudeSessionId: 'claude-1',
  costUsd: null,
  error: 'Something broke',
  peakRssKb: null,
  durationMs: 500,
  resumed: true,
};

beforeEach(() => {
  vi.clearAllMocks();
  clearBuffers();
  vi.mocked(db.getProjectByChannelId).mockReturnValue(fakeProject);
  vi.mocked(db.getOrCreateSession).mockReturnValue(fakeSession);
  vi.mocked(db.updateSessionStatus).mockReturnValue(undefined);
  vi.mocked(db.updateSessionClaudeId).mockReturnValue(undefined);
  vi.mocked(spawner.isRunning).mockReturnValue(false);
  vi.mocked(spawner.spawnClaude).mockResolvedValue(successResult);
  vi.mocked(fmt.formatResult).mockReturnValue('Done!');
  vi.mocked(fmt.splitMessage).mockReturnValue(['Done!']);
  vi.mocked(fmt.formatError).mockReturnValue('**Error:**\n```\nSomething broke\n```');
  vi.mocked(fmt.extractAttachments).mockReturnValue({ content: 'Done!', files: [] });
});

describe('handleMessage', () => {
  it('does nothing when channel is not registered', async () => {
    vi.mocked(db.getProjectByChannelId).mockReturnValue(null as any);
    const msg = createFakeMessage();
    await handleMessage(msg);
    expect(spawner.spawnClaude).not.toHaveBeenCalled();
  });

  it('buffers message when task is already running', async () => {
    vi.mocked(spawner.isRunning).mockReturnValue(true);
    const msg = createFakeMessage();
    await handleMessage(msg);

    // Should NOT reject — should buffer and react with 📋
    expect(msg.reply).not.toHaveBeenCalled();
    expect(msg.react).toHaveBeenCalledWith('\uD83D\uDCCB');
    expect(spawner.spawnClaude).not.toHaveBeenCalled();
    expect(getBufferedCount('/tmp/proj')).toBe(1);
  });

  it('spawns claude and replies with formatted result on success', async () => {
    const msg = createFakeMessage();
    await handleMessage(msg);

    expect(db.updateSessionStatus).toHaveBeenCalledWith('sess-1', 'running');
    expect(spawner.spawnClaude).toHaveBeenCalledWith(
      expect.objectContaining({
        prompt: '[TestUser] do something',
        projectPath: '/tmp/proj',
        claudeSessionId: 'claude-1',
      }),
    );
    expect(db.updateSessionClaudeId).toHaveBeenCalledWith('sess-1', 'claude-2');
    expect(db.updateSessionStatus).toHaveBeenCalledWith('sess-1', 'idle');
    expect(msg.reply).toHaveBeenCalledWith('Done!');
  });

  it('replies with error on spawn failure', async () => {
    vi.mocked(spawner.spawnClaude).mockResolvedValue(errorResult);
    const msg = createFakeMessage();
    await handleMessage(msg);

    expect(db.updateSessionStatus).toHaveBeenCalledWith('sess-1', 'error');
    expect(fmt.formatError).toHaveBeenCalledWith('Something broke');
    expect(msg.reply).toHaveBeenCalledWith(
      expect.stringContaining('Error'),
    );
  });

  it('retries with a fresh session only on the explicit "no conversation found" error', async () => {
    const deadSession: spawner.SpawnResult = {
      success: false,
      result: '',
      claudeSessionId: 'claude-1',
      costUsd: null,
      error: 'Claude exited with code 1: No conversation found with session ID: claude-1',
      peakRssKb: null,
      durationMs: 500,
      resumed: true,
    };

    vi.mocked(spawner.spawnClaude)
      .mockResolvedValueOnce(deadSession)
      .mockResolvedValueOnce(successResult);

    const msg = createFakeMessage();
    await handleMessage(msg);

    // Should have been called twice
    expect(spawner.spawnClaude).toHaveBeenCalledTimes(2);
    // Second call should have null session
    expect(spawner.spawnClaude).toHaveBeenLastCalledWith(
      expect.objectContaining({ claudeSessionId: null }),
    );
    // Session ID should have been cleared
    expect(db.updateSessionClaudeId).toHaveBeenCalledWith('sess-1', null);
    // Final result should be success
    expect(db.updateSessionStatus).toHaveBeenCalledWith('sess-1', 'idle');
  });

  it('keeps the session on errors that only mention "session" or "expired"', async () => {
    const sessionish: spawner.SpawnResult = {
      success: false,
      result: '',
      claudeSessionId: 'claude-1',
      costUsd: null,
      error: 'Claude exited with code 1: OAuth token has expired; session not found in cache',
      peakRssKb: null,
      durationMs: 500,
      resumed: true,
    };
    vi.mocked(spawner.spawnClaude).mockResolvedValue(sessionish);

    const msg = createFakeMessage();
    await handleMessage(msg);

    expect(spawner.spawnClaude).toHaveBeenCalledTimes(1);
    expect(db.updateSessionClaudeId).not.toHaveBeenCalledWith('sess-1', null);
    expect(db.updateSessionStatus).toHaveBeenCalledWith('sess-1', 'error');
  });

  it('includes referenced message context in prompt on reply', async () => {
    const refMessage = {
      content: 'original message',
      author: { tag: 'Author#5678', username: 'author5678', displayName: 'Author5678' },
      embeds: [],
    };

    const msg = createFakeMessage({
      content: 'follow up',
      reference: { messageId: 'ref-msg-1' },
    });
    msg.channel.messages.fetch.mockResolvedValue(refMessage);

    await handleMessage(msg);

    const prompt = vi.mocked(spawner.spawnClaude).mock.calls[0][0].prompt;
    expect(prompt).toContain('original message');
    expect(prompt).toContain('Author5678');
    expect(prompt).toContain('follow up');
  });

  it('includes forwarded message content in prompt', async () => {
    const snapshots = new Map([
      [
        'snap-1',
        {
          content: 'forwarded content',
          embeds: [],
        },
      ],
    ]);

    const msg = createFakeMessage({
      content: 'check this',
      messageSnapshots: snapshots,
    });

    await handleMessage(msg);

    const prompt = vi.mocked(spawner.spawnClaude).mock.calls[0][0].prompt;
    expect(prompt).toContain('forwarded content');
    expect(prompt).toContain('Forwarded message');
    expect(prompt).toContain('check this');
  });

  it('includes embed text from referenced message', async () => {
    const refMessage = {
      content: '',
      author: { tag: 'Bot#0000', username: 'bot0000', displayName: 'Bot' },
      embeds: [
        { title: 'Alert', description: 'Server is down' },
      ],
    };

    const msg = createFakeMessage({
      content: 'what happened?',
      reference: { messageId: 'ref-msg-2' },
    });
    msg.channel.messages.fetch.mockResolvedValue(refMessage);

    await handleMessage(msg);

    const prompt = vi.mocked(spawner.spawnClaude).mock.calls[0][0].prompt;
    expect(prompt).toContain('Alert: Server is down');
    expect(prompt).toContain('what happened?');
  });

  it('includes attachment info in prompt when files are attached', async () => {
    // Mock global fetch for attachment download
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      body: Readable.toWeb(Readable.from(Buffer.from('file content'))),
    });
    vi.stubGlobal('fetch', mockFetch);

    const attachments = createFakeAttachments([
      {
        name: 'report.pdf',
        url: 'https://cdn.discordapp.com/attachments/123/456/report.pdf',
        size: 1024,
        contentType: 'application/pdf',
      },
    ]);

    const msg = createFakeMessage({
      content: 'analyze this',
      attachments,
    });

    await handleMessage(msg);

    const prompt = vi.mocked(spawner.spawnClaude).mock.calls[0][0].prompt;
    expect(prompt).toContain('Attached files saved to disk');
    expect(prompt).toContain('report.pdf');
    expect(prompt).toContain('application/pdf');
    expect(prompt).toContain('analyze this');

    vi.unstubAllGlobals();
  });

  it('skips attachments over 25MB', async () => {
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      body: Readable.toWeb(Readable.from(Buffer.from(''))),
    });
    vi.stubGlobal('fetch', mockFetch);

    const attachments = createFakeAttachments([
      {
        name: 'huge.zip',
        url: 'https://cdn.discordapp.com/attachments/123/456/huge.zip',
        size: 30 * 1024 * 1024, // 30MB
        contentType: 'application/zip',
      },
    ]);

    const msg = createFakeMessage({
      content: 'process this',
      attachments,
    });

    await handleMessage(msg);

    // fetch should not be called for oversized attachment
    expect(mockFetch).not.toHaveBeenCalled();
    // Prompt should not contain attachment info
    const prompt = vi.mocked(spawner.spawnClaude).mock.calls[0][0].prompt;
    expect(prompt).not.toContain('Attached files');
    expect(prompt).toBe('[TestUser] process this');

    vi.unstubAllGlobals();
  });

  it('handles attachment download failure gracefully', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({ ok: false, status: 404 }),
    );

    const attachments = createFakeAttachments([
      {
        name: 'gone.txt',
        url: 'https://cdn.discordapp.com/attachments/123/456/gone.txt',
        size: 100,
        contentType: 'text/plain',
      },
    ]);

    const msg = createFakeMessage({
      content: 'read this',
      attachments,
    });

    await handleMessage(msg);

    // Should still proceed without attachment
    expect(spawner.spawnClaude).toHaveBeenCalled();
    const prompt = vi.mocked(spawner.spawnClaude).mock.calls[0][0].prompt;
    expect(prompt).not.toContain('Attached files');

    vi.unstubAllGlobals();
  });
});

describe('message buffer', () => {
  it('combines buffered messages with next direct message', async () => {
    // Step 1: buffer two messages while busy
    vi.mocked(spawner.isRunning).mockReturnValue(true);

    const msg1 = createFakeMessage({ content: 'first queued' });
    const msg2 = createFakeMessage({ content: 'second queued' });
    await handleMessage(msg1);
    await handleMessage(msg2);

    expect(getBufferedCount('/tmp/proj')).toBe(2);
    expect(msg1.react).toHaveBeenCalledWith('\uD83D\uDCCB');
    expect(msg2.react).toHaveBeenCalledWith('\uD83D\uDCCB');

    // Step 2: project becomes free, new message flushes buffer
    vi.mocked(spawner.isRunning).mockReturnValue(false);
    vi.mocked(spawner.spawnClaude).mockResolvedValue(successResult);

    const directMsg = createFakeMessage({ content: 'direct message' });
    await handleMessage(directMsg);

    // Single batch call with all 3 messages (buffered + new)
    expect(spawner.spawnClaude).toHaveBeenCalledTimes(1);

    const prompt = vi.mocked(spawner.spawnClaude).mock.calls[0][0].prompt;
    expect(prompt).toContain('first queued');
    expect(prompt).toContain('second queued');
    expect(prompt).toContain('direct message');
    expect(prompt).toContain('3 more messages');
    expect(prompt).toContain('[Message 1/3 from TestUser]');
    expect(prompt).toContain('[Message 2/3 from TestUser]');
    expect(prompt).toContain('[Message 3/3 from TestUser]');

    // Buffer should be empty now
    expect(getBufferedCount('/tmp/proj')).toBe(0);

    // Reply goes to the last message (direct)
    expect(directMsg.reply).toHaveBeenCalled();
  });

  it('combines single buffered message with direct message', async () => {
    vi.mocked(spawner.isRunning).mockReturnValue(true);

    const queued = createFakeMessage({ content: 'solo queued' });
    await handleMessage(queued);

    vi.mocked(spawner.isRunning).mockReturnValue(false);
    vi.mocked(spawner.spawnClaude).mockResolvedValue(successResult);

    const direct = createFakeMessage({ content: 'trigger' });
    await handleMessage(direct);

    expect(spawner.spawnClaude).toHaveBeenCalledTimes(1);

    const prompt = vi.mocked(spawner.spawnClaude).mock.calls[0][0].prompt;
    expect(prompt).toContain('solo queued');
    expect(prompt).toContain('trigger');
    expect(prompt).toContain('2 more messages');
    expect(prompt).toContain('[Message 1/2 from TestUser]');
    expect(prompt).toContain('[Message 2/2 from TestUser]');
  });

  it('attributes batch messages to correct authors', async () => {
    vi.mocked(spawner.isRunning).mockReturnValue(true);

    const msg1 = createFakeMessage({
      content: 'hello',
      author: { username: 'alice', displayName: 'Alice' },
      member: { displayName: 'Alice' },
    });
    const msg2 = createFakeMessage({
      content: 'world',
      author: { username: 'bob', displayName: 'Bob' },
      member: { displayName: 'Bob' },
    });
    await handleMessage(msg1);
    await handleMessage(msg2);

    vi.mocked(spawner.isRunning).mockReturnValue(false);
    vi.mocked(spawner.spawnClaude).mockResolvedValue(successResult);

    const direct = createFakeMessage({
      content: 'trigger',
      author: { username: 'carol', displayName: 'Carol' },
      member: { displayName: 'Carol' },
    });
    await handleMessage(direct);

    const prompt = vi.mocked(spawner.spawnClaude).mock.calls[0][0].prompt;
    expect(prompt).toContain('[Message 1/3 from Alice]');
    expect(prompt).toContain('hello');
    expect(prompt).toContain('[Message 2/3 from Bob]');
    expect(prompt).toContain('world');
    expect(prompt).toContain('[Message 3/3 from Carol]');
    expect(prompt).toContain('trigger');
  });
});

describe('stickers and GIFs', () => {
  it('includes sticker context in prompt for sticker-only message', async () => {
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      body: Readable.toWeb(Readable.from(Buffer.from('PNG data'))),
    });
    vi.stubGlobal('fetch', mockFetch);

    const stickers = createFakeStickers([
      { id: 'stk-1', name: 'Wave', description: 'Waving hello', format: 1, url: 'https://cdn.discordapp.com/stickers/stk-1.png' },
    ]);

    const msg = createFakeMessage({ content: '', stickers });
    await handleMessage(msg);

    const prompt = vi.mocked(spawner.spawnClaude).mock.calls[0][0].prompt;
    expect(prompt).toContain('[Sticker sent]');
    expect(prompt).toContain('"Wave"');
    expect(prompt).toContain('Waving hello');
    expect(prompt).toContain('use Read tool to see it');

    vi.unstubAllGlobals();
  });

  it('includes text-only context for Lottie stickers', async () => {
    const stickers = createFakeStickers([
      { id: 'stk-2', name: 'Sparkle', description: 'Sparkle animation', format: 3, url: 'https://cdn.discordapp.com/stickers/stk-2.json' },
    ]);

    const msg = createFakeMessage({ content: 'ooh!', stickers });
    await handleMessage(msg);

    const prompt = vi.mocked(spawner.spawnClaude).mock.calls[0][0].prompt;
    expect(prompt).toContain('"Sparkle"');
    expect(prompt).toContain('Lottie format, no image available');
    expect(prompt).not.toContain('use Read tool');
    expect(prompt).toContain('ooh!');
  });

  it('includes both sticker context and text content', async () => {
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      body: Readable.toWeb(Readable.from(Buffer.from('PNG data'))),
    });
    vi.stubGlobal('fetch', mockFetch);

    const stickers = createFakeStickers([
      { id: 'stk-3', name: 'Heart Eyes', description: null, format: 1, url: 'https://cdn.discordapp.com/stickers/stk-3.png' },
    ]);

    const msg = createFakeMessage({ content: 'I love it!', stickers });
    await handleMessage(msg);

    const prompt = vi.mocked(spawner.spawnClaude).mock.calls[0][0].prompt;
    expect(prompt).toContain('"Heart Eyes"');
    expect(prompt).toContain('I love it!');

    vi.unstubAllGlobals();
  });

  it('extracts GIF context from Tenor gifv embeds', async () => {
    const embeds = [
      {
        data: { type: 'gifv' },
        url: 'https://tenor.com/view/thumbs-up-okay-nice-gif-12345',
        description: null,
        title: null,
        provider: { name: 'Tenor' },
      },
    ];

    const msg = createFakeMessage({
      content: 'https://tenor.com/view/thumbs-up-okay-nice-gif-12345',
      embeds,
    });
    await handleMessage(msg);

    const prompt = vi.mocked(spawner.spawnClaude).mock.calls[0][0].prompt;
    expect(prompt).toContain('[GIF sent]');
    expect(prompt).toContain('thumbs up okay nice');
  });

  it('handles sticker download failure gracefully', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({ ok: false, status: 500 }),
    );

    const stickers = createFakeStickers([
      { id: 'stk-4', name: 'Broken', description: 'A broken sticker', format: 1, url: 'https://cdn.discordapp.com/stickers/stk-4.png' },
    ]);

    const msg = createFakeMessage({ content: '', stickers });
    await handleMessage(msg);

    const prompt = vi.mocked(spawner.spawnClaude).mock.calls[0][0].prompt;
    expect(prompt).toContain('"Broken"');
    expect(prompt).toContain('A broken sticker');
    // Should degrade to text-only, no file path
    expect(prompt).toContain('PNG format, no image available');

    vi.unstubAllGlobals();
  });

  it('includes sticker context in reply to sticker-only message', async () => {
    const refMessage = {
      content: '',
      author: { displayName: 'Mari', username: 'mari' },
      embeds: [],
      stickers: createFakeStickers([
        { id: 'stk-5', name: 'Thumbs Up', description: 'Thumbs up', format: 1, url: 'https://cdn.discordapp.com/stickers/stk-5.png' },
      ]),
    };

    const msg = createFakeMessage({
      content: 'what does that mean?',
      reference: { messageId: 'ref-sticker-msg' },
    });
    msg.channel.messages.fetch.mockResolvedValue(refMessage);

    await handleMessage(msg);

    const prompt = vi.mocked(spawner.spawnClaude).mock.calls[0][0].prompt;
    expect(prompt).toContain('Replying to message from Mari');
    expect(prompt).toContain('[Sticker: "Thumbs Up" — Thumbs up]');
    expect(prompt).toContain('what does that mean?');
  });

  it('includes sticker context in forwarded sticker-only message', async () => {
    const snapshots = new Map([
      [
        'snap-sticker',
        {
          content: '',
          embeds: [],
          stickers: createFakeStickers([
            { id: 'stk-6', name: 'Party', description: 'Party popper', format: 1, url: 'https://cdn.discordapp.com/stickers/stk-6.png' },
          ]),
        },
      ],
    ]);

    const msg = createFakeMessage({
      content: 'look at this',
      messageSnapshots: snapshots,
    });
    await handleMessage(msg);

    const prompt = vi.mocked(spawner.spawnClaude).mock.calls[0][0].prompt;
    expect(prompt).toContain('Forwarded message');
    expect(prompt).toContain('[Sticker: "Party" — Party popper]');
    expect(prompt).toContain('look at this');
  });

  it('includes sticker sent as reply to a message', async () => {
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      body: Readable.toWeb(Readable.from(Buffer.from('PNG data'))),
    });
    vi.stubGlobal('fetch', mockFetch);

    const refMessage = {
      content: 'How are you today?',
      author: { displayName: 'Chuck', username: 'chuck' },
      embeds: [],
      stickers: new Map(),
    };

    const stickers = createFakeStickers([
      { id: 'stk-7', name: 'Happy', description: 'Happy face', format: 1, url: 'https://cdn.discordapp.com/stickers/stk-7.png' },
    ]);

    const msg = createFakeMessage({
      content: '',
      reference: { messageId: 'ref-msg-happy' },
      stickers,
    });
    msg.channel.messages.fetch.mockResolvedValue(refMessage);

    await handleMessage(msg);

    const prompt = vi.mocked(spawner.spawnClaude).mock.calls[0][0].prompt;
    expect(prompt).toContain('Replying to message from Chuck');
    expect(prompt).toContain('How are you today?');
    expect(prompt).toContain('[Sticker sent]');
    expect(prompt).toContain('"Happy"');

    vi.unstubAllGlobals();
  });

  it('includes buffered sticker message in batch prompt', async () => {
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      body: Readable.toWeb(Readable.from(Buffer.from('PNG data'))),
    });
    vi.stubGlobal('fetch', mockFetch);

    // Step 1: buffer a sticker message while busy
    vi.mocked(spawner.isRunning).mockReturnValue(true);

    const stickerMsg = createFakeMessage({
      content: '',
      stickers: createFakeStickers([
        { id: 'stk-8', name: 'Fire', description: null, format: 1, url: 'https://cdn.discordapp.com/stickers/stk-8.png' },
      ]),
    });
    await handleMessage(stickerMsg);
    expect(getBufferedCount('/tmp/proj')).toBe(1);

    // Step 2: project becomes free, new text message flushes buffer
    vi.mocked(spawner.isRunning).mockReturnValue(false);
    vi.mocked(spawner.spawnClaude).mockResolvedValue(successResult);

    const textMsg = createFakeMessage({ content: 'what was that?' });
    await handleMessage(textMsg);

    const prompt = vi.mocked(spawner.spawnClaude).mock.calls[0][0].prompt;
    expect(prompt).toContain('2 more messages');
    expect(prompt).toContain('[Message 1/2 from TestUser]');
    expect(prompt).toContain('"Fire"');
    expect(prompt).toContain('[Message 2/2 from TestUser]');
    expect(prompt).toContain('what was that?');

    vi.unstubAllGlobals();
  });
});
