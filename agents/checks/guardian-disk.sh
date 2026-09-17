#!/usr/bin/env bash
# Занятость дисков и что именно занимает место. Read-only.
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"
report_header "💽 ДИСКИ И МЕСТО"

report_section "📦 ТОМА"
while read -r size used avail pct mount; do
  report_gauge "${pct%%%}" "$mount ($used из $size)"
done < <(df -h --output=size,used,avail,pcent,target / /var /home /tmp 2>/dev/null | tail -n +2 | awk '!seen[$5]++')

report_section "🧮 INODES"
for m in / /var /home; do
  [ -d "$m" ] || continue
  I=$(df -i "$m" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')
  [ -n "$I" ] && report_gauge "$I" "inodes $m"
done

report_section "🐘 ЧТО ЗАНИМАЕТ МЕСТО"
du -xh --max-depth=1 /var/lib 2>/dev/null | sort -rh | head -4 | awk '{printf "  %-8s %s\n", $1, $2}'
du -xh --max-depth=1 /var/log 2>/dev/null | sort -rh | head -3 | awk '{printf "  %-8s %s\n", $1, $2}'
du -sh /var/backups/hermes 2>/dev/null | awk '{printf "  %-8s %s\n", $1, $2}'
command -v docker >/dev/null && docker system df --format '{{.Type}} {{.Size}} ({{.Reclaimable}} можно освободить)' 2>/dev/null | sed 's/^/  docker: /'

PCT=$(df --output=pcent / | tail -1 | tr -dc '0-9')
ACTIONS=()
if num_ge "$PCT" 85; then
  ACTIONS+=("корень заполнен на ${PCT}% — освободить место: docker system prune, старые архивы в /var/backups/hermes")
elif num_ge "$PCT" 70; then
  ACTIONS+=("корень на ${PCT}% — держать в уме, уборка не срочная")
else
  ACTIONS+=("места достаточно (${PCT}%) — действий не требуется")
fi
ACTIONS+=("крупные каталоги: du -xh --max-depth=2 / | sort -rh | head -20")
report_proof "df -h · du -x --max-depth=1 / · lsblk · journalctl --disk-usage"
report_footer "${ACTIONS[@]}"
