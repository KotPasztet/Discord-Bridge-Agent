# Discord Bash Bridge

- `scripts/discord_bash_bridge.sh` — Bash bridge.
- `SKILL.md` — instructions for AI agents using Discord as the user communication channel.
- `discord_messages.log` — created automatically in this directory when user DMs arrive.
- `command_history.log` — created automatically when interactive commands are logged.

## Quick start

```bash
source ./scripts/discord_bash_bridge.sh
discord_start BOT_TOKEN DISCORD_USER_ID
discord_send "**Bridge online**"
await_discord
```

The bot needs permission to create/read/send messages in the user's DM. Install `curl` and `jq`.
