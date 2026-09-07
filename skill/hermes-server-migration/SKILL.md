---
name: hermes-server-migration
description: >
  Migrate a Hermes Agent instance between servers with zero loss of memory,
  cron jobs, or sessions. Covers state.db corruption recovery (sqlite backup
  API), path-rewrite sweeps across files AND database contents, venv rebuild,
  systemd --user adaptation, cron-DB restoration, drift_skip pinning, and
  Telegram reconnect verification. Triggers: "hermes migration", "move hermes
  to a new server", "database disk image is malformed", "state database file
  was replaced underneath this process", "cron jobs point at the old server",
  "leftover old user paths", "gateway-crash database disk image", "drift_skip"
  — use in any Hermes server-change / migration context.
---

# Skill: Hermes Server Migration

Protocol for moving a Hermes Agent instance (or any agent built on the same
architecture: state.db + systemd --user units + venv + cron system) from
server A to server B with **zero loss of memory, cron jobs, sessions, or
capability**.

Automated version: `hermes-migrate.sh` in the repo root
(<https://github.com/aligundogar/hermes-server-migration>) — six phases:
stop → db-backup → transfer → fix-paths → activate → verify.

## Prerequisites

- SSH key access to both machines
- `python3` ≥ 3.10 on both (for the sqlite backup API)
- Target will need node 22+ (installed during activation if missing)
- ~1–2 h wall clock for a 6–7 GB Hermes home; companion dirs add linearly

## Phase 0 — Inventory (before touching anything)

```bash
ssh src 'du -sh ~/.hermes; du -sh ~/.hermes/* | sort -rh | head -20'
ssh src 'systemctl --user list-units "hermes-*" --no-pager'
ssh src 'crontab -l'
ssh src 'ls ~/.hermes/cron/'          # jobs.json + executions/deliveries/notepad.db
```

Write down **companion directories** (notes, crawlers, memory stores,
scripts, credential-adjacent config dirs). Forgetting these is the #1 cause
of a "half-migrated" agent: the brain arrives but the hands stay behind.

## Phase 1 — Stop the SOURCE first (order matters)

```bash
ssh src 'systemctl --user stop hermes-dashboard hermes-gateway hermes-gateway-* hermes-acp'
# back up + disable the source crontab (prevents double-execution)
ssh src 'crontab -l > ~/crontab-backup.txt && printf "# migrated\n" | crontab -'
```

Why first:

- rsync over a **live sqlite + WAL** yields a corrupt copy
  (`database disk image is malformed`)
- two gateways running the same Telegram/WhatsApp sessions fight over
  polling and duplicate deliveries

## Phase 2 — CLEAN state.db snapshots (raw copy is FORBIDDEN)

Use the sqlite **backup API**, never `cp`:

```bash
ssh src 'python3 - <<PY
import sqlite3, os, glob
targets  = [os.path.expanduser("~/.hermes/state.db")]
targets += glob.glob(os.path.expanduser("~/.hermes/profiles/*/state.db"))
targets += glob.glob(os.path.expanduser("~/.hermes/cron/*.db"))
for db in targets:
    if not os.path.exists(db): continue
    dst = "/tmp/" + os.path.basename(os.path.dirname(db)) + "-" + os.path.basename(db) + ".clean"
    src = sqlite3.connect(db); out = sqlite3.connect(dst)
    src.backup(out); out.close()
    ok = sqlite3.connect(dst).execute("PRAGMA integrity_check").fetchone()[0]
    src.close(); print(db, "->", dst, ok)
    assert ok == "ok"
PY'
```

### ⚠️ The trap that gets everyone: per-profile and per-subsystem DBs

The **main** `state.db` can pass integrity check while **every profile DB and
all three cron DBs are malformed**. They were written by different processes
at different times; a live rsync corrupts each independently. Verify ALL of:

| Database | Contains | If malformed |
|----------|----------|--------------|
| `~/.hermes/state.db` | sessions, messages, memory (FTS5), system prompts, gateway routing | agent loses conversation memory |
| `profiles/*/state.db` | per-persona memory + sessions | that persona amnesiac; gateway may crash on open |
| `cron/executions.db`, `cron/deliveries.db`, `cron/notepad.db` | scheduler state | **cron-scheduler thread crashes permanently** — zero jobs fire, no errors surfaced to chat |

## Phase 3 — Transfer

```bash
rsync -az --exclude hermes-agent/venv --exclude __pycache__ --exclude '*.pyc' \
  ~/.hermes/ dest:.hermes/
rsync -az ... ~/companion-dir/ dest:companion-dir/   # each companion dir
```

- If no direct SSH path exists between the two servers, add the source's key
  to the destination's `authorized_keys` (keep it afterwards — useful for the
  fleet) or relay through a jump machine with a tar pipe.
- `hermes-agent/venv/` is **never** transferred: it embeds absolute paths.

## Phase 4 — Path-rewrite sweep (the most-skipped phase)

Rewrite `old_home → new_home` in three layers:

1. **Text files** — configs, skills, scripts, notes, `cron/jobs.json`
   (skip: `sessions/`, `logs/`, `backups/`, `cache/`, `*.pyc`, venv —
   historical/harmless)
2. **Companion dirs** — same treatment
3. **Inside every database** — cron prompts, memories, system prompts,
   gateway routing, async delegations live as *strings in rows*:

```python
import sqlite3, glob, os
dbs = [os.path.expanduser("~/.hermes/state.db")]
dbs += glob.glob(os.path.expanduser("~/.hermes/profiles/*/state.db"))
dbs += glob.glob(os.path.expanduser("~/.hermes/cron/*.db"))
for db in dbs:
    con = sqlite3.connect(db)
    tables = [r[0] for r in con.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")]
    for t in [t for t in tables if not t.endswith(("_fts","_data","_idx","_docsize","_config","_content"))]:
        for (c,) in con.execute(f'PRAGMA table_info("{t}")'):
            try:
                con.execute(f'UPDATE "{t}" SET "{c}" = replace("{c}", ?, ?) WHERE "{c}" LIKE ?',
                            (OLD, NEW, f"%{OLD}%"))
            except Exception: pass
    con.commit(); con.close()
```

A real migration rewrote **10,678 rows** this way (messages, tool_calls,
reasoning, system_prompts, gateway_routing, async_delegations,
delivery_obligations) plus ~700 files. Skipping the DB layer means every old
conversation and cron prompt still points at a home that no longer exists.

## Phase 5 — Activation

```bash
# venv rebuild (absolute paths from the source are dead)
cd ~/.hermes/hermes-agent && python3 -m venv venv
./venv/bin/pip install --upgrade pip && ./venv/bin/pip install -e .

# adapt systemd --user units: paths + dashboard --host flag
sed -i "s|/home/old|/home/new|g; s|src-hostname|dst-hostname|g" \
    ~/.config/systemd/user/hermes-*.service

systemctl --user daemon-reload
sudo loginctl enable-linger "$USER"     # services survive logout
systemctl --user enable --now hermes-dashboard hermes-gateway hermes-gateway-*
```

## Phase 6 — Verification

```bash
systemctl --user is-active hermes-dashboard hermes-gateway hermes-gateway-*
curl -s http://127.0.0.1:9119/ -o /dev/null -w '%{http_code}\n'      # 200/302
# every DB, not just the main one:
python3 - <<PY
import sqlite3, glob, os
for db in [os.path.expanduser("~/.hermes/state.db")] + \
          glob.glob(os.path.expanduser("~/.hermes/profiles/*/state.db")) + \
          glob.glob(os.path.expanduser("~/.hermes/cron/*.db")):
    print(db, sqlite3.connect(db).execute("PRAGMA integrity_check").fetchone()[0])
PY
journalctl --user -u 'hermes-gateway*' --since '-5 min' \
  | grep 'Connected to Telegram'    # one line per bot
grep -rl OLD_HOME ~/.hermes --exclude-dir=venv | grep -cvE 'sessions/|logs/|backups/|cache/'   # 0
```

## Known special cases

### "state database file was replaced underneath this process"

You replaced a DB while its gateway was running. Unwritten messages were
diverted to `sessions/<session_id>.jsonl` and
`pending_messages/pending-*.json` — not lost, but **stop the service, put the
right DB in place, restart** before anything else.

### "Invalid Host header. Dashboard requests must use the bound hostname…"

Dashboard Host-header validation (GHSA-ppp5-vxwm-4cf7). Either set the public
hostname in config (`dashboard.public_url: https://hermes.internal.example.net`)
or bind `0.0.0.0` (explicit opt-out of this protection layer).

### OpenStack Security Group: port "open" but unreachable

The process listens, `curl` works **on the guest**, external clients time out,
and iptables/nft show nothing — it is the **Neutron Security Group** (invisible
from inside the guest). Add an ingress rule via the API:

```bash
curl -X POST "$NEUTRON/v2.0/security-group-rules" -H "X-Auth-Token: $TOKEN" \
  -d '{"security_group_rule":{"direction":"ingress","protocol":"tcp",
       "port_range_min":9119,"port_range_max":9119,
       "remote_ip_prefix":"192.168.0.0/24","security_group_id":"<sg-id>"}}'
```

Get the SG id from the *compute* API
(`GET /v2.1/servers/<id>/os-security-groups`) — names are ambiguous across
tenants; the id from the network list may not be the one attached.

### Cron DBs malformed → scheduler thread dies silently

Symptom: gateways active, no errors in chat, but **zero cron outputs**.
`journalctl --user -u hermes-gateway` shows
`[gateway-crash] thread cron-scheduler raised DatabaseError: database disk
image is malformed`. Fix: restore clean cron DBs (phase 2), restart.

### drift_skip — cron jobs silently skipped after migration

After migration the global inference config (provider/model) usually differs
from when jobs were created. **Unpinned jobs refuse to spend** and log
`drift_skip:silent` — the scheduler looks healthy while doing nothing. Output
files contain the signature `[drift_skip:silent] Skipped to prevent unintended
spend`. Fix by pinning each job to the intended config:

```bash
for ID in $(python3 -c "import json; print(' '.join(j['id'] for j in json.load(open('$HOME/.hermes/cron/jobs.json'))['jobs']))"); do
  hermes cron edit "$ID" --provider openrouter --model minimax/minimax-m3:free
done
```

Verify at the next fire: the output file must not contain `(FAILED)` or
`drift_skip`.

### Cron prompt references a script that never existed

If a cron output reports "script not found" for a path that yields zero
results even in git history, the prompt itself was stale. Replace the command
in `cron/jobs.json` with the working equivalent, then rewrite paths as usual.

### Prompt-injection guard flags the agent's own persona files

Persona/SOUL files that document security tooling (C2 frameworks, pentest
repos) can trip built-in threat signatures such as `known_c2_framework`
(`tools/threat_patterns.py`). This is a false positive for the operator's own
content: approve through the command-approval flow rather than patching the
signature file (updates overwrite it).

## Recovery order when several things are broken at once

1. Stop all Hermes services on the destination
2. Restore clean DBs (state + profiles + cron), delete stray `-wal`/`-shm`
3. Run the path-rewrite sweep
4. Start services
5. Watch the journal for `gateway-crash` — if absent, the scheduler is alive
6. Force-proof: wait for the next scheduled fire or trigger one manually;
   confirm no `drift_skip` and no `(FAILED)` in the output file
