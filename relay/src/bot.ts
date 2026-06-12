import {
  Client,
  GatewayIntentBits,
  SlashCommandBuilder,
  REST,
  Routes,
  ChatInputCommandInteraction,
  ChannelType,
} from 'discord.js';
import * as db from './db.js';
import * as router from './router.js';
import * as watcher from './watcher.js';

let client: Client;

export async function start(token: string): Promise<void> {
  client = new Client({
    intents: [
      GatewayIntentBits.Guilds,
      GatewayIntentBits.GuildMessages,
      GatewayIntentBits.MessageContent,
    ],
  });

  client.on('ready', async () => {
    console.log(
      `[${new Date().toISOString()}] Relay online as ${client.user!.tag}`,
    );
    await registerSlashCommands(token);
    watcher.startWatcher(client);
  });

  client.on('messageCreate', async (message) => {
    if (message.author.bot) return;
    // Allow messages with text, replies, forwards, or attachments
    const hasContent = !!message.content.trim();
    const hasReference = !!message.reference?.messageId;
    const hasForward = !!message.messageSnapshots?.size;
    const hasAttachments = !!message.attachments.size;
    const hasStickers = !!message.stickers.size;
    if (!hasContent && !hasReference && !hasForward && !hasAttachments && !hasStickers) return;

    // Only respond in registered channels
    const project = db.getProjectByChannelId(message.channel.id);
    if (!project) return;

    try {
      await router.handleMessage(message);
    } catch (err) {
      console.error(
        `[${new Date().toISOString()}] Error handling message:`,
        err,
      );
      await message
        .reply('Internal error. Check relay logs.')
        .catch(() => {});
    }
  });

  client.on('interactionCreate', async (interaction) => {
    if (!interaction.isChatInputCommand()) return;
    try {
      await handleCommand(interaction);
    } catch (err) {
      console.error(
        `[${new Date().toISOString()}] Error handling command:`,
        err,
      );
      const reply = interaction.replied || interaction.deferred
        ? interaction.followUp.bind(interaction)
        : interaction.reply.bind(interaction);
      await reply({ content: 'Command failed. Check relay logs.', ephemeral: true }).catch(() => {});
    }
  });

  client.on('error', (err) => {
    console.error(`[${new Date().toISOString()}] Discord client error:`, err);
  });

  await client.login(token);
}

export async function destroy(): Promise<void> {
  watcher.stopWatcher();
  if (client) {
    client.destroy();
  }
}

export function getClient(): Client {
  return client;
}

// --- Slash Commands ---

async function registerSlashCommands(token: string): Promise<void> {
  const commands = [
    new SlashCommandBuilder()
      .setName('project')
      .setDescription('Manage projects')
      .addSubcommand((sub) =>
        sub
          .setName('add')
          .setDescription('Register a project')
          .addStringOption((o) =>
            o.setName('name').setDescription('Project name').setRequired(true),
          )
          .addStringOption((o) =>
            o
              .setName('path')
              .setDescription('Absolute path on Mac')
              .setRequired(true),
          )
          .addChannelOption((o) =>
            o
              .setName('channel')
              .setDescription('Discord channel')
              .setRequired(true),
          )
          .addStringOption((o) =>
            o
              .setName('identity')
              .setDescription('chuck-wiki MCP identity (e.g., chuck-main, chuck-project-rancho)')
              .setRequired(false),
          ),
      )
      .addSubcommand((sub) =>
        sub.setName('list').setDescription('List all projects'),
      )
      .addSubcommand((sub) =>
        sub
          .setName('remove')
          .setDescription('Remove a project')
          .addStringOption((o) =>
            o
              .setName('name')
              .setDescription('Project name')
              .setRequired(true),
          ),
      )
      .addSubcommand((sub) =>
        sub
          .setName('reconcile')
          .setDescription('Enable/disable the nightly reconcile for a project')
          .addStringOption((o) =>
            o
              .setName('name')
              .setDescription('Project name')
              .setRequired(true),
          )
          .addBooleanOption((o) =>
            o
              .setName('enabled')
              .setDescription('true = run nightly reconcile, false = leave the session alone')
              .setRequired(true),
          ),
      )
      .addSubcommand((sub) =>
        sub
          .setName('set-identity')
          .setDescription('Set or clear chuck-wiki MCP identity for a project')
          .addStringOption((o) =>
            o
              .setName('name')
              .setDescription('Project name')
              .setRequired(true),
          )
          .addStringOption((o) =>
            o
              .setName('identity')
              .setDescription('Identity string, or empty to clear')
              .setRequired(false),
          ),
      ),
    new SlashCommandBuilder()
      .setName('status')
      .setDescription('Show session status for all projects'),
    new SlashCommandBuilder()
      .setName('webhook')
      .setDescription('Manage channel webhooks')
      .addSubcommand((sub) =>
        sub
          .setName('create')
          .setDescription('Create (or return existing) chuck-wiki webhook in this channel'),
      ),
  ];

  const rest = new REST({ version: '10' }).setToken(token);
  await rest.put(Routes.applicationCommands(client.user!.id), {
    body: commands.map((c) => c.toJSON()),
  });
  console.log(`[${new Date().toISOString()}] Slash commands registered`);
}

async function handleCommand(
  interaction: ChatInputCommandInteraction,
): Promise<void> {
  const { commandName } = interaction;

  if (commandName === 'status') {
    return handleStatus(interaction);
  }

  if (commandName === 'project') {
    const sub = interaction.options.getSubcommand();
    if (sub === 'add') return handleProjectAdd(interaction);
    if (sub === 'list') return handleProjectList(interaction);
    if (sub === 'remove') return handleProjectRemove(interaction);
    if (sub === 'reconcile') return handleProjectReconcile(interaction);
    if (sub === 'set-identity') return handleProjectSetIdentity(interaction);
  }

  if (commandName === 'webhook') {
    const sub = interaction.options.getSubcommand();
    if (sub === 'create') return handleWebhookCreate(interaction);
  }
}

async function handleProjectAdd(
  interaction: ChatInputCommandInteraction,
): Promise<void> {
  const name = interaction.options.getString('name', true);
  const path = interaction.options.getString('path', true);
  const channel = interaction.options.getChannel('channel', true);
  const identity = interaction.options.getString('identity', false);

  if (channel.type !== ChannelType.GuildText) {
    await interaction.reply({
      content: 'Channel must be a text channel.',
      ephemeral: true,
    });
    return;
  }

  // Check for duplicates
  if (db.getProjectByName(name)) {
    await interaction.reply({
      content: `Project "${name}" already exists.`,
      ephemeral: true,
    });
    return;
  }
  if (db.getProjectByChannelId(channel.id)) {
    await interaction.reply({
      content: `Channel <#${channel.id}> is already mapped to a project.`,
      ephemeral: true,
    });
    return;
  }

  const project = db.createProject(channel.id, path, name, true, identity);
  const identityLine = project.identity ? `\nIdentity: \`${project.identity}\`` : '';
  await interaction.reply(
    `Project **${project.name}** registered.\nChannel: <#${project.discord_channel_id}>\nPath: \`${project.project_path}\`${identityLine}`,
  );
}

async function handleProjectReconcile(
  interaction: ChatInputCommandInteraction,
): Promise<void> {
  const name = interaction.options.getString('name', true);
  const enabled = interaction.options.getBoolean('enabled', true);

  const updated = db.setProjectReconcileEnabled(name, enabled);
  if (!updated) {
    await interaction.reply({
      content: `Project "${name}" not found.`,
      ephemeral: true,
    });
    return;
  }
  await interaction.reply(
    enabled
      ? `Nightly reconcile **enabled** for **${name}**.`
      : `Nightly reconcile **disabled** for **${name}** — its session will not be closed at night.`,
  );
}

async function handleProjectSetIdentity(
  interaction: ChatInputCommandInteraction,
): Promise<void> {
  const name = interaction.options.getString('name', true);
  const raw = interaction.options.getString('identity', false);
  const identity = raw && raw.trim().length > 0 ? raw.trim() : null;

  const updated = db.updateProjectIdentity(name, identity);
  if (!updated) {
    await interaction.reply({
      content: `Project "${name}" not found.`,
      ephemeral: true,
    });
    return;
  }
  await interaction.reply(
    identity
      ? `Identity for **${name}** set to \`${identity}\`.`
      : `Identity for **${name}** cleared.`,
  );
}

async function handleProjectList(
  interaction: ChatInputCommandInteraction,
): Promise<void> {
  const projects = db.getAllProjects();
  if (projects.length === 0) {
    await interaction.reply({
      content: 'No projects registered. Use `/project add` to register one.',
      ephemeral: true,
    });
    return;
  }

  const lines = projects.map((p) => {
    const id = p.identity ? ` — id:\`${p.identity}\`` : '';
    const rec = p.reconcile_enabled ? '' : ' — reconcile:off';
    return `**${p.name}** — <#${p.discord_channel_id}> — \`${p.project_path}\`${id}${rec}`;
  });
  await interaction.reply(lines.join('\n'));
}

async function handleProjectRemove(
  interaction: ChatInputCommandInteraction,
): Promise<void> {
  const name = interaction.options.getString('name', true);
  const deleted = db.deleteProject(name);
  if (deleted) {
    await interaction.reply(`Project **${name}** removed.`);
  } else {
    await interaction.reply({
      content: `Project "${name}" not found.`,
      ephemeral: true,
    });
  }
}

const WEBHOOK_NAME = 'chuck-wiki-webhook';

async function handleWebhookCreate(
  interaction: ChatInputCommandInteraction,
): Promise<void> {
  const channel = interaction.channel;
  if (!channel || channel.type !== ChannelType.GuildText) {
    await interaction.reply({
      content: 'Use this in a text channel.',
      ephemeral: true,
    });
    return;
  }

  try {
    const existing = await channel.fetchWebhooks();
    const found = existing.find((w) => w.name === WEBHOOK_NAME);
    if (found) {
      await interaction.reply({
        content: `Existing webhook **${WEBHOOK_NAME}** in <#${channel.id}>:\n\`${found.url}\`\n\nPaste into Mac Mini launchd env as \`CHUCK_WIKI_DISCORD_WEBHOOK_URL\`.`,
        ephemeral: true,
      });
      return;
    }

    const created = await channel.createWebhook({
      name: WEBHOOK_NAME,
      reason: 'chuck-wiki MCP auto-process notifications',
    });
    await interaction.reply({
      content: `Created webhook **${WEBHOOK_NAME}** in <#${channel.id}>:\n\`${created.url}\`\n\nPaste into Mac Mini launchd env as \`CHUCK_WIKI_DISCORD_WEBHOOK_URL\`. Treat it like a secret — anyone with this URL can post to this channel.`,
      ephemeral: true,
    });
  } catch (err) {
    const msg = (err as Error).message;
    const hint = msg.toLowerCase().includes('missing permissions')
      ? '\nHint: bot needs **Manage Webhooks** permission on this channel.'
      : '';
    await interaction.reply({
      content: `Failed to create webhook: ${msg}${hint}`,
      ephemeral: true,
    });
  }
}

async function handleStatus(
  interaction: ChatInputCommandInteraction,
): Promise<void> {
  const sessions = db.getAllSessions();
  if (sessions.length === 0) {
    await interaction.reply({
      content: 'No active sessions.',
      ephemeral: true,
    });
    return;
  }

  const statusEmoji: Record<string, string> = {
    idle: '\u{1F7E2}',     // green circle
    running: '\u{1F7E1}',  // yellow circle
    error: '\u{1F534}',    // red circle
  };

  const lines = sessions.map((s) => {
    const emoji = statusEmoji[s.status] || '\u26AA';
    const active = s.last_active
      ? ` (last: ${s.last_active})`
      : '';
    return `${emoji} **${s.project_name}** — ${s.status}${active}`;
  });

  await interaction.reply(lines.join('\n'));
}
