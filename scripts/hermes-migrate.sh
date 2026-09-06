#!/usr/bin/env bash
# =============================================================================
# hermes-migrate.sh — Server-to-server migration for Hermes Agent instances
# Repo: https://github.com/aligundogar/hermes-server-migration
# License: MIT — no API keys or secrets required; fully parameterized.
#
# Usage:
#   ./hermes-migrate.sh migrate   <src_host> <src_user> <dst_host> <dst_user> [extra_dir ...]
#   ./hermes-migrate.sh fix-paths <host> <user> <old_home> <new_home> [extra_dir ...]
#   ./hermes-migrate.sh verify    <host> <user> <old_home>
#
# Example (generic):
#   ./hermes-migrate.sh migrate old-server old-user new-server new-user \
#       notes scripts my-memory-store
#
# Environment:
#   COMMON_DIRS   extra dirs scanned by fix-paths when none are passed
#                 (default: "scripts notes .openclaw")
#
# Battle-tested in production across multiple real migrations (2026-09)
# =============================================================================
set -euo pipefail

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; RST=$'\e[0m'
log()  { echo "${GRN}[MIG]${RST} $*"; }
warn() { echo "${YLW}[WARN]${RST} $*"; }
die()  { echo "${RED}[ERR]${RST} $*" >&2; exit 1; }
ssh_run() { ssh -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new "$@"; }

# -----------------------------------------------------------------------------
# Phase 1: stop services on the SOURCE
# (otherwise: "file changed as we read it", corrupted sqlite, session conflicts)
# -----------------------------------------------------------------------------
phase_stop_source() {
  local host="$1" user="$2"
  log "Phase 1: stopping Hermes services on source ${host}..."
  ssh_run "${user}@${host}" \
    'systemctl --user stop hermes-dashboard hermes-gateway hermes-gateway-* hermes-acp 2>/dev/null;
     if crontab -l 2>/dev/null | grep -q .; then
       crontab -l > ~/crontab-backup-migrate.txt
       printf "# migrated\n" | crontab -
       echo "crontab backed up and disabled"
     fi'
  warn "Source services are now OFFLINE — bots answer from the destination only."
}

# -----------------------------------------------------------------------------
# Phase 2: CLEAN state.db snapshot (sqlite backup API — never a raw copy!)
# Raw copy of a live sqlite + WAL => "database disk image is malformed".
# -----------------------------------------------------------------------------
phase_backup_db() {
  local host="$1" user="$2"
  log "Phase 2: clean state.db snapshots via sqlite backup API..."
  ssh_run "${user}@${host}" '
    python3 - <<PY
import sqlite3, os, glob
targets = [os.path.expanduser("~/.hermes/state.db")]
targets += glob.glob(os.path.expanduser("~/.hermes/profiles/*/state.db"))
targets += glob.glob(os.path.expanduser("~/.hermes/cron/*.db"))  # executions/deliveries/notepad — scheduler crash source if skipped
for db in targets:
    if not os.path.exists(db):
        continue
    dst = "/tmp/" + os.path.basename(os.path.dirname(db)) + "-" + os.path.basename(db) + ".clean"
    src = sqlite3.connect(db)
    out = sqlite3.connect(dst)
    src.backup(out)
    out.close()
    ok = sqlite3.connect(dst).execute("PRAGMA integrity_check").fetchone()[0]
    src.close()
    print(f"{db} -> {dst} [{ok}]")
    assert ok == "ok", "integrity check failed"
PY'
}

# -----------------------------------------------------------------------------
# Phase 3: transfer (venv EXCLUDED — it is not portable, rebuilt on target)
# -----------------------------------------------------------------------------
phase_transfer() {
  local shost="$1" suser="$2" dhost="$3" duser="$4"; shift 4
  local extra=("$@")
  log "Phase 3: rsync (~/.hermes + ${#extra[@]} companion dirs)..."
  ssh_run "${suser}@${shost}" "
    rsync -az --info=stats1 \
      --exclude hermes-agent/venv --exclude __pycache__ --exclude '*.pyc' \
      -e 'ssh -o StrictHostKeyChecking=accept-new' \
      ~/.hermes/ ${duser}@${dhost}:.hermes/
    for d in ${extra[*]:-}; do
      [ -d ~/\$d ] && rsync -az --info=stats1 -e 'ssh -o StrictHostKeyChecking=accept-new' ~/\$d/ ${duser}@${dhost}:\$d/
    done
  "
  log "Transfer complete."
}

# -----------------------------------------------------------------------------
# Phase 4: path rewrite (old_home -> new_home)
#   Scope: text files, cron jobs.json, companion dirs,
#   AND inside every state.db (cron prompts, memories, system prompts, messages).
#   Skipped: sessions/, logs/, backups/, cache/, *.pyc (historical, harmless).
# -----------------------------------------------------------------------------
phase_fix_paths() {
  local host="$1" user="$2" old_home="$3" new_home="$4"; shift 4
  local dirs=("${@:-}")
  [ ${#dirs[@]} -eq 0 ] && IFS=' ' read -ra dirs <<< "${COMMON_DIRS:-scripts notes .openclaw}"
  log "Phase 4: path rewrite ${old_home} -> ${new_home} ..."
  ssh_run "${user}@${host}" \
    OLD="$old_home" NEW="$new_home" DIRS="${dirs[*]}" bash -s <<'PATCH'
set -e
# 4a. Hermes text files
grep -rl "$OLD" ~/.hermes 2>/dev/null | grep -vE 'venv|node_modules|hermes-agent/(src|test|docs)|sessions/|logs/|state-snapshots/|backups/|request_dump|\.log$|\.pyc$|__pycache__|\.bak|cache/|\.db$|cron/output' | while read -r f; do
  [ -f "$f" ] && sed -i "s|$OLD|$NEW|g" "$f"
done
# 4b. Cron job definitions
[ -f ~/.hermes/cron/jobs.json ] && sed -i "s|$OLD|$NEW|g" ~/.hermes/cron/jobs.json
# 4c. Companion dirs
for d in $DIRS; do
  [ -d ~/"$d" ] || continue
  grep -rl "$OLD" ~/"$d" 2>/dev/null | grep -vE '\.pyc$|__pycache__|\.log$|node_modules' | while read -r f; do
    sed -i "s|$OLD|$NEW|g" "$f"
  done
done
# 4d. Inside every state.db (cron prompts, memory, system prompts, messages)
python3 - <<PY
import sqlite3, glob, os
dbs = [os.path.expanduser("~/.hermes/state.db")]
dbs += glob.glob(os.path.expanduser("~/.hermes/profiles/*/state.db"))
dbs += glob.glob(os.path.expanduser("~/.hermes/cron/*.db"))
total = 0
skip_suffix = ("_fts", "_data", "_idx", "_docsize", "_config", "_content")
for db in dbs:
    con = sqlite3.connect(db)
    tables = [r[0] for r in con.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")]
    tables = [t for t in tables if not t.endswith(skip_suffix)]
    for t in tables:
        for (c,) in con.execute(f'PRAGMA table_info("{t}")').fetchall():
            try:
                cur = con.execute(
                    f'UPDATE "{t}" SET "{c}" = replace("{c}", ?, ?) WHERE "{c}" LIKE ?',
                    (os.environ["OLD"], os.environ["NEW"], "%" + os.environ["OLD"] + "%"))
                total += cur.rowcount
            except Exception:
                pass
    con.commit(); con.close()
print(f"rewrote {total} rows inside databases")
PY
log "Path rewrite complete."
PATCH
}

# -----------------------------------------------------------------------------
# Phase 5: venv rebuild + systemd unit adaptation + start services
# -----------------------------------------------------------------------------
phase_activate() {
  local host="$1" user="$2" old_dash_host="$3" new_dash_host="$4" old_home="$5" new_home="$6"
  log "Phase 5: venv rebuild + systemd + start..."
  ssh_run "${user}@${host}" \
    OH="$old_home" NH="$new_home" ODH="$old_dash_host" NDH="$new_dash_host" bash -s <<'ACT'
set -e
# venv from the source carries absolute paths — rebuild it
cd ~/.hermes/hermes-agent
[ -d venv ] || python3 -m venv venv
./venv/bin/pip install -q --upgrade pip
./venv/bin/pip install -q -e .
# adapt systemd --user units (paths + dashboard --host)
for u in ~/.config/systemd/user/hermes-*.service; do
  [ -f "$u" ] && sed -i "s|$OH|$NH|g; s|$ODH|$NDH|g" "$u"
done
systemctl --user daemon-reload
(loginctl enable-linger "$USER" 2>/dev/null || sudo loginctl enable-linger "$USER" 2>/dev/null) \
  && echo "linger enabled" || warn "enable-linger failed — services stop on logout"
systemctl --user enable --now hermes-dashboard hermes-gateway hermes-gateway-* 2>/dev/null || true
sleep 8
systemctl --user is-active hermes-dashboard hermes-gateway 2>/dev/null || true
ACT
  log "Services active."
}

# -----------------------------------------------------------------------------
# Phase 6: verification
# -----------------------------------------------------------------------------
phase_verify() {
  local host="$1" user="$2" old_home="${3:-}"
  log "Phase 6: verification..."
  ssh_run "${user}@${host}" \
    OLD="${old_home:-__none__}" bash -s <<'VER'
echo -n "dashboard 9119: "; curl -s -m 5 -o /dev/null -w "%{http_code}\n" http://127.0.0.1:9119/
echo -n "state.db integrity: "; python3 -c "import sqlite3; print(sqlite3.connect('$HOME/.hermes/state.db').execute('PRAGMA integrity_check').fetchone()[0])"
python3 - <<PY
import sqlite3, glob, os
bad = []
for db in [os.path.expanduser("~/.hermes/state.db")] + glob.glob(os.path.expanduser("~/.hermes/profiles/*/state.db")):
    r = sqlite3.connect(db).execute("PRAGMA integrity_check").fetchone()[0]
    if r != "ok": bad.append(db)
print("profile dbs:", "all ok" if not bad else f"MALFORMED: {bad}")
PY
if [ "$OLD" != "__none__" ]; then
  echo -n "leftover old-home refs (active files): "
  grep -rl "$OLD" ~/.hermes 2>/dev/null | grep -cvE "venv|node_modules|hermes-agent|sessions/|logs/|state-snapshots/|backups/|\.pyc$|__pycache__|cache/|\.db$|cron/output" || true
fi
echo -n "telegram reconnects (last 2 min): "
journalctl --user -u hermes-gateway -u hermes-gateway-* --since "-2 min" --no-pager 2>/dev/null | grep -c "Connected to Telegram" || true
VER
}

# -----------------------------------------------------------------------------
case "${1:-}" in
  migrate)
    shift; [ $# -ge 4 ] || die "migrate <src_host> <src_user> <dst_host> <dst_user> [extra_dir ...]"
    phase_stop_source "$1" "$2"
    phase_backup_db "$1" "$2"
    phase_transfer "$1" "$2" "$3" "$4" "${@:5}"
    phase_fix_paths "$3" "$4" "/home/$2" "/home/$4" "${@:5}"
    # dashboard --host: source tailnet/hostname -> destination (pass your own values if needed)
    phase_activate "$3" "$4" "$1" "$3" "/home/$2" "/home/$4"
    phase_verify "$3" "$4" "/home/$2"
    log "MIGRATION COMPLETE. Remember: disable source units so they never come back:"
    log "  ssh ${2}@${1} 'systemctl --user disable hermes-dashboard hermes-gateway hermes-gateway-*'"
    ;;
  fix-paths)
    shift; [ $# -ge 4 ] || die "fix-paths <host> <user> <old_home> <new_home> [extra_dir ...]"
    phase_fix_paths "$@"
    ;;
  verify)
    shift; [ $# -ge 2 ] || die "verify <host> <user> [old_home]"
    phase_verify "$@"
    ;;
  *)
    sed -n '2,20p' "$0"; exit 1 ;;
esac
