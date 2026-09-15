#!/usr/bin/env bash
# scripts/verify-backup.sh — prove the newest backup can actually be restored.
#
# WHY: a tar that lists cleanly only proves bytes exist. The failure mode we hit
# on 2026-09-15 was a backup of the WRONG directory that still verified. So this
# extracts the newest state archive into a scratch directory and compares content
# hashes against the live tree — the same thing a restore would do, without
# touching the live installation.
#
# Read-only with respect to the live system: writes only under a temp dir.
# Exit 0 = restorable, 1 = not restorable, 2 = nothing to verify.
set -euo pipefail

DEST="${HERMES_BACKUP_DIR:-/var/backups/hermes}"
STATE_DIR="${HERMES_HOME:-/home/hermes/.hermes}"
ARCHIVE="${1:-$(ls -1t "$DEST"/hermes-state-*.tar.gz 2>/dev/null | head -1)}"

[[ -n "$ARCHIVE" && -f "$ARCHIVE" ]] || { echo "no state archive in $DEST to verify"; exit 2; }

echo "=== restore verification ==="
echo "  archive : $ARCHIVE"
echo "  age     : $(( ( $(date +%s) - $(stat -c %Y "$ARCHIVE") ) / 3600 ))h"
echo "  live    : $STATE_DIR"

tar -tzf "$ARCHIVE" >/dev/null 2>&1 || { echo "  FAIL: archive fails integrity check"; exit 1; }
ENTRIES=$(tar -tzf "$ARCHIVE" | wc -l)
echo "  entries : $ENTRIES"
(( ENTRIES >= ${HERMES_BACKUP_MIN_ENTRIES:-50} )) || { echo "  FAIL: implausibly small archive"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
tar -xzf "$ARCHIVE" -C "$TMP"

# Locate the extracted state dir. tar strips the leading "/" (it prints
# "Removing leading `/' from member names"), so an archive of /home/hermes/.hermes
# unpacks as <tmp>/home/hermes/.hermes — taking the first top-level directory would
# give <tmp>/home and every path check below would fail for the wrong reason.
# Match on the directory NAME first, then fall back to the Hermes-home markers.
WANT="$(basename "$STATE_DIR")"                      # e.g. ".hermes"
EXTRACTED="$(find "$TMP" -type d -name "$WANT" 2>/dev/null | head -1)"
if [[ -z "$EXTRACTED" ]]; then
    EXTRACTED="$(find "$TMP" -type d -name 'config.yaml' -printf '%h\n' 2>/dev/null | head -1)"
fi
if [[ -z "$EXTRACTED" ]]; then
    EXTRACTED="$(find "$TMP" -type d \( -name memories -o -name kanban \) -printf '%h\n' 2>/dev/null | head -1)"
fi
[[ -n "$EXTRACTED" ]] || { echo "  FAIL: no Hermes home found inside the archive"; exit 1; }
echo "  restored to: $EXTRACTED (scratch)"

# --- the part that matters: does the restored CONTENT match the live content? --
CHECKED=0; FAILED=0
check() {  # check <relative path>
    local rel="$1" live="$STATE_DIR/$1" got="$EXTRACTED/$1"
    if [[ ! -e "$live" ]]; then
        printf '  skip   %-34s (not present live)\n' "$rel"; return
    fi
    if [[ ! -e "$got" ]]; then
        printf '  FAIL   %-34s missing in archive\n' "$rel"; FAILED=$((FAILED + 1)); return
    fi
    if [[ -f "$live" ]]; then
        local a b
        a=$(sha256sum "$live" | cut -d' ' -f1)
        b=$(sha256sum "$got" | cut -d' ' -f1)
        if [[ "$a" == "$b" ]]; then
            printf '  ok     %-34s sha256 %s\n' "$rel" "${a:0:16}…"
        else
            printf '  FAIL   %-34s sha256 differs\n' "$rel"; FAILED=$((FAILED + 1))
        fi
    else
        printf '  ok     %-34s present\n' "$rel"
    fi
    CHECKED=$((CHECKED + 1))
}

check "memories/MEMORY.md"
check "config.yaml"
check "kanban/boards/hermes-os/kanban.db"
check "profiles/${HERMES_PROFILE:-default}/SOUL.md"

# Count-level sanity: the archive must carry the same shape, not just a file or two.
LIVE_PROFILES=$(find "$STATE_DIR/profiles" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
GOT_PROFILES=$(find "$EXTRACTED/profiles" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
echo "  profiles: live=$LIVE_PROFILES restored=$GOT_PROFILES"
if (( LIVE_PROFILES > 0 && GOT_PROFILES < LIVE_PROFILES )); then
    echo "  FAIL: archive is missing profile directories"; FAILED=$((FAILED + 1))
fi

# --- and it must not have smuggled secrets in ---------------------------------
SECRETS=$(find "$EXTRACTED" \( -name '.env' -o -name '*.pem' -o -name 'authorized_keys' -o -name '*token*' \) 2>/dev/null | wc -l)
echo "  secret-shaped files in archive: $SECRETS (must be 0)"
(( SECRETS == 0 )) || { echo "  FAIL: backup contains secret-shaped files"; FAILED=$((FAILED + 1)); }

echo
if (( FAILED > 0 )); then
    echo "RESTORE VERIFICATION FAILED: $FAILED of $CHECKED checks failed"
    exit 1
fi
echo "RESTORE VERIFICATION OK: $CHECKED content checks, $ENTRIES entries, no secrets"
