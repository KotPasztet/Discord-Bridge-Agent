# Discord Bash Bridge

- `scripts/discord_bash_bridge.sh` — Bash bridge.
- `SKILL.md` — instructions for AI agents using Discord as the user communication channel.
- `discord_messages.log` — created automatically in this directory when user DMs arrive.
- `command_history.log` — created automatically when interactive commands are logged.

## Prerequisites & Bot Setup

Install `curl` and `jq`, then configure a Discord bot:

1. **Create a Bot & Get the Token (`BOT_TOKEN`):**
   - Go to the [Discord Developer Portal](https://discord.com/developers/applications) and click **New Application**.
   - Open the **Bot** tab in the left sidebar.
   - Click **Reset Token** (or **View Token**) and copy the generated `BOT_TOKEN`. Keep it secret.

2. **Enable Required Intents:**
   - In the **Bot** tab, scroll down to **Privileged Gateway Intents**.
   - Enable **Message Content Intent** (required so the bridge can read incoming DM text) and click **Save Changes**.

3. **Add the Bot to a Mutual Server:**
   - Discord bots cannot initiate DMs with users unless they share at least one server.
   - Open the **OAuth2** -> **URL Generator** tab in the left sidebar.
   - Under **Scopes**, check `bot`.
   - Copy the generated URL at the bottom, open it in your browser, and invite the bot to any server you are already a member of (e.g., a private testing server).

4. **Start a DM & Get Your User ID (`DISCORD_USER_ID`):**
   - In Discord, go to **User Settings** -> **Advanced** and enable **Developer Mode**.
   - Right-click your own profile/avatar and click **Copy User ID** to get your `DISCORD_USER_ID`.
   - Find the bot in the member list of the mutual server, click on it, and **send it an initial DM** (e.g., `hi`) so Discord opens the DM channel and allows the bot to message you back.

## Quick start

```bash
source ./scripts/discord_bash_bridge.sh
discord_start BOT_TOKEN DISCORD_USER_ID
discord_send "**Bridge online**"
await_discord