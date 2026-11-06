# Installing oh-my-status

[← Back to README](../README.md)

## Via Marketplace (recommended)

In Claude Code, run:

```
/plugin marketplace add sw-willie-wu/oh-my-claude
/plugin install oh-my-status@oh-my-claude
/reload-plugins
```

Then run setup to configure the statusline:

```
/oh-my-status:setup
```

Restart Claude Code to see the statusline.

## Local Development

```bash
git clone https://github.com/sw-willie-wu/oh-my-claude.git
claude --plugin-dir ./oh-my-claude/plugins/oh-my-status
```

Then run `/oh-my-status:setup` and restart Claude Code.

## Standalone (no plugin system)

```bash
git clone https://github.com/sw-willie-wu/oh-my-claude.git
bash oh-my-claude/install.sh
```

Restart Claude Code to see the statusline.
