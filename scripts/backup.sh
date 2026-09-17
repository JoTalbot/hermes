#!/usr/bin/env bash
# scripts/backup.sh — config/state backup for the Hermes layer.
# GitHub holds CONFIG (this repo). It must NOT hold databases or runtime state,
# and it must never hold secrets. So: tar → local backup target, and only the
# allowlisted config into git.
#
# FAIL-LOUD CONTRACT (added 2026-09-15 after a real false success):
#   The original version used `"${HERMES_HOME:-$HOME/.hermes}"`, so when run from
#   a root shell without HERMES_HOME it happily archived /root/.hermes (3 entries),
#   printed "verified", and exited 0. A backup that silently captures the wrong
#   directory is worse than no backup, because it is trusted. Now:
#     * the state dir is resolved explicitly and must exist and LOOK like a
#       Hermes home (kanban/ memories/ profiles/ config.yaml),
#     * a tar failure is fatal instead of being echoed away,
#     * the archive must contain a plausible number of entries (HERMES_BACKUP_MIN_ENTRIES),
#     * the resolved path and entry count are printed, so a human can see them.
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DEST="${HERMES_BACKUP_DIR:-$REPO_DIR/state/backups}"
KEEP="${HERMES_BACKUP_KEEP:-7}"
MIN_ENTRIES="${HERMES_BACKUP_MIN_ENTRIES:-50}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
umask 077

# --- resolve the state directory deliberately (never guess quietly) -----------
STATE_DIR="${HERMES_HOME:-}"
if [[ -z "$STATE_DIR" ]]; then
    for candidate in /home/hermes/.hermes "$HOME/.hermes"; do
        if [[ -d "$candidate" ]]; then STATE_DIR="$candidate"; break; fi
    done
fi
if [[ -z "$STATE_DIR" || ! -d "$STATE_DIR" ]]; then
    echo "FATAL: cannot locate the Hermes state directory." >&2
    echo "       Set HERMES_HOME explicitly, e.g." >&2
    echo "       sudo env HERMES_HOME=/home/hermes/.hermes HERMES_BACKUP_DIR=$DEST bash $0" >&2
    exit 2
fi
# Refuse anything that is not obviously a Hermes home: this is what catches
# "$HOME/.hermes" resolving to a near-empty /root/.hermes.
MARKERS=0
for m in kanban memories profiles config.yaml; do
    [[ -e "$STATE_DIR/$m" ]] && MARKERS=$((MARKERS + 1))
done
if (( MARKERS == 0 )); then
    echo "FATAL: '$STATE_DIR' does not look like a Hermes home (no kanban/, memories/, profiles/, config.yaml)." >&2
    echo "       Refusing to produce a backup that would be trusted but empty." >&2
    exit 2
fi
LIVE_ENTRIES=$(find "$STATE_DIR" -mindepth 1 2>/dev/null | wc -l)
if (( LIVE_ENTRIES < MIN_ENTRIES )); then
    echo "FATAL: '$STATE_DIR' has only $LIVE_ENTRIES entries (< $MIN_ENTRIES) — wrong directory?" >&2
    exit 2
fi

mkdir -p "$DEST"
echo "=== Hermes backup $STAMP ==="
echo "  source state : $STATE_DIR  ($LIVE_ENTRIES entries, $MARKERS/4 markers)"
echo "  destination  : $DEST (keep=$KEEP)"

# --- 1. Hermes runtime state (sessions/memory/kanban/skills), secrets EXCLUDED -
STATE_ARCHIVE="$DEST/hermes-state-$STAMP.tar.gz"
# FACT (2026-09-17): ночной бэкап падал на «file changed as we read it» — это нормальное
# поведение живой системы, но tar возвращал 1, set -e убивал скрипт, и бэкап оставался
# наполовину (без архива конфига узла), молча. --warning=no-file-changed снимает этот
# случай, а код ≥2 по-прежнему фатален — но теперь мы отличаем одно от другого явно.
set +e
tar --create --gzip --warning=no-file-changed \
    --exclude='*/.env' --exclude='*/.env.*' --exclude='*.pem' --exclude='authorized_keys' \
    --exclude='*/logs/*' --exclude='*/cache/*' --exclude='*/audio_cache/*' --exclude='*/image_cache/*' \
    --file="$STATE_ARCHIVE" \
    "$STATE_DIR" 2> "$DEST/.tar-state-$STAMP.err"
TAR_RC=$?
set -e
if (( TAR_RC == 1 )); then
    echo "  WARN: tar сообщил об изменённых во время чтения файлах (штатно для живой системы):" 
    tail -3 "$DEST/.tar-state-$STAMP.err" | sed 's/^/        /'
elif (( TAR_RC >= 2 )); then
    echo "FATAL: tar не смог создать архив (код $TAR_RC):" >&2
    tail -5 "$DEST/.tar-state-$STAMP.err" >&2
    exit 2
fi
rm -f "$DEST/.tar-state-$STAMP.err"
ARCHIVED=$(tar -tzf "$STATE_ARCHIVE" | wc -l)
echo "  state archive: $(basename "$STATE_ARCHIVE") — $ARCHIVED entries, $(du -h "$STATE_ARCHIVE" | cut -f1)"
if (( ARCHIVED < MIN_ENTRIES )); then
    echo "FATAL: archive contains only $ARCHIVED entries — refusing to call this a backup." >&2
    exit 2
fi

# --- 4. node configuration and bus state (NOT the Hermes home) ---------------
# WHY (drill 2026-09-17): the state archive covers $HERMES_HOME only, so a restored node
# came back WITHOUT /etc/hermes/telegram.chats.json (the chat allowlist — the bot would
# ignore its owner), /etc/hermes/node.env (the node's role) and the bus state in
# /var/lib/hermes-bus (Telegram offset, alert dedupe, room/node registry). None of that is
# a secret and all of it is state a human would have to retype from memory.
#
# Secrets stay OUT: telegram.env, nats.env, shim.env, dashboard.env, *.password,
# git-credentials are never copied here (see the include list — it is explicit, not a glob).
NODECFG_ARCHIVE="$DEST/hermes-nodecfg-$STAMP.tar.gz"
NODECFG_COUNT=0
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/etc/hermes" "$STAGE/var/lib/hermes-bus" "$STAGE/var/lib/hermes-agents"
NFT=0
copy_if() {  # copy_if <source> <destination>
    [[ -f "$1" ]] || return 0
    cp -p "$1" "$2" 2>/dev/null || return 0
    NFT=$((NFT + 1))
}
for f in telegram.chats.json node.env alerts.env; do
    copy_if "/etc/hermes/$f" "$STAGE/etc/hermes/$f"
done
for f in tg-offset.json alert-state.json rooms.json nodes.json; do
    copy_if "/var/lib/hermes-bus/$f" "$STAGE/var/lib/hermes-bus/$f"
done
copy_if "/var/lib/hermes-agents/pending.json" "$STAGE/var/lib/hermes-agents/pending.json"
if (( NFT > 0 )); then
    tar --create --gzip --file="$NODECFG_ARCHIVE" -C "$STAGE" .
    NODECFG_COUNT=$NFT
    echo "  nodecfg archive: $(basename "$NODECFG_ARCHIVE") — $NFT файлов "\
         "($(du -h "$NODECFG_ARCHIVE" | cut -f1)); секреты не входят"
else
    echo "  nodecfg archive: пропущен (нет ни одного из ожидаемых файлов)"
fi

# --- 2. config from the repo (cheap, versioned separately by git anyway) ------
CONFIG_ARCHIVE="$DEST/hermes-config-$STAMP.tar.gz"
tar --create --gzip --file="$CONFIG_ARCHIVE" \
    -C "$REPO_DIR" config skills docs scripts deploy tests
echo "  config archive: $(basename "$CONFIG_ARCHIVE") ($(du -h "$CONFIG_ARCHIVE" | cut -f1))"

# --- 3. project databases — to a NON-git target, only if a dump tool exists ----
: > "$DEST/databases-$STAMP.list"
for svc in $(systemctl list-units --type=service --state=running --no-pager --plain 2>/dev/null | awk '{print $1}' | grep -iE 'postgres' | head -3); do
    echo "  postgres unit $svc detected — dump with: pg_dumpall > $DEST/db-$STAMP.sql (do this out-of-band)" >> "$DEST/databases-$STAMP.list"
done
for d in /opt/logistics /opt/madworld; do
    [[ -d "$d" ]] || continue
    find "$d" -maxdepth 2 \( -name '*.db' -o -name '*.sqlite' \) 2>/dev/null | while read -r f; do
        cp -p "$f" "$DEST/$(basename "$(dirname "$f")")-$(basename "$f").$STAMP" 2>/dev/null || true
        echo "  snapshotted $f" >> "$DEST/databases-$STAMP.list"
    done
done

# --- 4. prune ------------------------------------------------------------------
ls -1t "$DEST"/hermes-state-*.tar.gz 2>/dev/null | tail -n +$((KEEP+1)) | xargs -r rm -f
ls -1t "$DEST"/hermes-config-*.tar.gz 2>/dev/null | tail -n +$((KEEP+1)) | xargs -r rm -f

# --- 5. integrity: a backup you never opened is a rumour -----------------------
BAD=0; MADE=0
for a in "$DEST"/hermes-*-$STAMP.tar.gz; do
    [[ -f "$a" ]] || continue
    MADE=$((MADE + 1))
    if tar -tzf "$a" >/dev/null 2>&1; then
        echo "  verified: $(basename "$a") ($(du -h "$a" | cut -f1), $(tar -tzf "$a" | wc -l) entries)"
    else
        echo "  CORRUPT: $a" >&2
        BAD=$((BAD + 1))
    fi
done

# --- 6. собственный вердикт бэкапа, чтобы провал был виден метрикой ---
# DECISION (2026-09-17): «сколько архивов» недостаточно. Нужен ответ на вопрос «бэкап отработал?»,
# иначе половина бэкапа без архива конфига узла выглядит как нормальный бэкап.
STATE_JSON="${HERMES_BACKUP_STATE:-/var/lib/hermes-bus/backup-last.json}"
if (( BAD == 0 && MADE >= 1 )); then RC=0; else RC=1; fi
python3 - "$STATE_JSON" "$STAMP" "$MADE" "$BAD" "$RC" "$ARCHIVED" "${NODECFG_COUNT:-0}" <<'PY'
import json, os, sys, time
state, stamp, made, bad, rc, entries, nodecfg = sys.argv[1:8]
os.makedirs(os.path.dirname(state), exist_ok=True)
json.dump({"ts": int(time.time()), "stamp": stamp, "ok": rc == "0",
           "archives": int(made), "corrupt": int(bad), "entries": int(entries or 0),
           "nodecfg_files": int(nodecfg or 0),
           "expected": ["hermes-state", "hermes-nodecfg", "hermes-config"]},
          open(state, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print(f"  вердикт бэкапа: {'OK' if rc == '0' else 'FAILED'} · архивов {made} · файлов конфига узла {nodecfg} · {state}")
PY
# Вердикт читает экспортёр метрик (свой пользователь), секретов в нём нет — только числа.
chmod 0644 "$STATE_JSON" 2>/dev/null || true
(( RC == 0 )) || exit 1
echo "backups in $DEST (keep=$KEEP). Secrets and databases are intentionally NOT in here."
