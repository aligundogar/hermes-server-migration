# hermes-server-migration

**Production-ready script + procedure** to migrate a [Hermes Agent](https://github.com/acoliver/hermes-agent) instance between servers with **zero loss of memory, cron jobs, or sessions**.

Battle-tested across 3 real migrations (2026-09): 514 MB state.db, 22 cron jobs, 3 Telegram bots, 43 GB of notes.

```
┌─────────────┐   rsync (venv excluded)  ┌─────────────┐
│ SOURCE host │ ───────────────────────► │ DEST host   │
│ services ▼  │   sqlite backup API      │ services ▲  │
│ crontab ▼   │   path rewrite sweep     │ venv rebuild│
└─────────────┘                          └─────────────┘
```

## Why this exists

Migrating Hermes is not `rsync -a`. Known traps — all solved in this repo:

| Trap | Symptom | Fix |
|------|---------|-----|
| Raw-copying a live `state.db` | `database disk image is malformed` | sqlite **backup API** (`src.backup(dst)`) + integrity check |
| Replacing `state.db` under a running gateway | "state database file was replaced underneath this process" → unwritten messages diverted to `sessions/*.jsonl` | Stop dest services → replace → restart |
| Copying the `venv` | Absolute paths point at the old server; silent breakage | Never migrate venv; rebuild on target: `python3 -m venv venv && pip install -e .` |
| Rewriting only file paths | Cron prompts, memories and system prompts keep the old path **inside the database** | SQL `replace()` sweep across every text column of every table |
| systemd `--user` without linger | Services die on logout | `loginctl enable-linger $USER` |
| Leaving the source server running | Two gateways fight over the same Telegram/WhatsApp session | Stop + **disable** source services, take crontab offline |
| Dashboard Host-header validation | "Invalid Host header" (GHSA-ppp5-vxwm-4cf7 fix) | Set `dashboard.public_url` in config to the public hostname |
| Port open yet unreachable (OpenStack) | Security Group is invisible inside the guest; TCP just times out | Add a Neutron ingress rule (if you run on OpenStack) |

## Usage

```bash
# Full migration (6 phases: stop → db-backup → transfer → fix-paths → activate → verify)
./scripts/hermes-migrate.sh migrate <src_host> <src_user> <dst_host> <dst_user> [extra_dirs...]

# Path rewrite only (old home → new home)
./scripts/hermes-migrate.sh fix-paths <host> <user> /home/old_user /home/new_user

# Verification only
./scripts/hermes-migrate.sh verify <host> <user>
```

Example:

```bash
./scripts/hermes-migrate.sh migrate old-server old-user new-server new-user \
    notes scripts my-memory-store
```

The script contains **no secrets**: it needs no API keys or tokens — only SSH access and `python3` on both ends.

## Manual procedure (without the script)

See [`skill/hermes-server-migration/SKILL.md`](skill/hermes-server-migration/SKILL.md) for the step-by-step protocol with rationale, verification commands, and recovery recipes.

## What gets migrated

| Component | Migrated | Notes |
|-----------|----------|-------|
| `~/.hermes/state.db` (messages, memory, sessions, FTS index) | ✅ | via sqlite backup API |
| `profiles/` (per-profile state.db + config + skills) | ✅ | each integrity-checked |
| `cron/jobs.json` (all scheduled tasks) | ✅ | + path rewrite |
| `skills/`, `notes/`, `SOUL.md`, `config.yaml` | ✅ | |
| Telegram/WhatsApp session tokens | ✅ | live in the DB; auto-reconnect after restart |
| `hermes-agent/venv/` | ❌ on purpose | rebuilt on target — phase 5 |
| Companion dirs (notes, crawlers, memory stores) | ✅ | parameterized list |

## Verification (the migration isn't done until these pass)

```bash
systemctl --user is-active hermes-dashboard hermes-gateway   # active
curl -s http://127.0.0.1:9119/ -o /dev/null -w '%{http_code}\n'   # 200/302
python3 -c "import sqlite3; print(sqlite3.connect('$HOME/.hermes/state.db').execute('PRAGMA integrity_check').fetchone())"  # ok
journalctl --user -u hermes-gateway --since '-2 min' | grep 'Connected to Telegram'  # one per bot
grep -rc "old_home" ~/.hermes --include='*.yaml' --exclude-dir=venv  # 0
```

## License

MIT
