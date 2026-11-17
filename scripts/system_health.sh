#!/usr/bin/env bash
# system_health.sh - collect host health, compare against thresholds, log, and set an exit code.
# Exit codes: 0 = healthy, 1 = warning, 2 = critical (usable from cron, systemd, Nagios-style checks).
set -euo pipefail

VERSION="1.0.0"
CPU_WARN=90 MEM_WARN=85 DISK_WARN=80
CPU_CRIT=98 MEM_CRIT=95 DISK_CRIT=95
LOAD_WARN=""                       # default: 2 x number of CPUs
LOG_FILE="${HEALTH_LOG_FILE:-./health_log.txt}"
MAX_BYTES=1048576                  # rotate at 1 MiB
KEEP=5                             # keep health_log.txt.1 .. .5
WEBHOOK_URL="${HEALTH_WEBHOOK_URL:-}"   # optional Slack/Discord webhook, read from the environment
JSON=0

usage() {
  cat <<USAGE
Usage: ${0##*/} [options]

Collects CPU, memory, disk (all mounted filesystems), load average and the top 5
processes by memory. Appends a timestamped entry to the log file.

Thresholds (percent unless noted; a value ABOVE the limit triggers the state):
  --cpu N          CPU warning threshold            (default ${CPU_WARN})
  --mem N          memory warning threshold         (default ${MEM_WARN})
  --disk N         disk warning threshold           (default ${DISK_WARN})
  --load N         1-minute load warning threshold  (default 2 x CPUs)
  --cpu-crit N     CPU critical threshold           (default ${CPU_CRIT})
  --mem-crit N     memory critical threshold        (default ${MEM_CRIT})
  --disk-crit N    disk critical threshold          (default ${DISK_CRIT})

Output / logging:
  --json           print and log JSON (one object per line) instead of text
  --log-file PATH  log file                         (default ${LOG_FILE})
  --max-size BYTES rotate when the log reaches this size (default ${MAX_BYTES})
  --keep N         number of rotated files to keep  (default ${KEEP})
  -h, --help       show this help
  -V, --version    show version

Environment: HEALTH_LOG_FILE, HEALTH_WEBHOOK_URL (notify on warning/critical).
Exit codes: 0 healthy, 1 warning, 2 critical, 64 usage error.
USAGE
}

die() { echo "error: $*" >&2; exit 64; }

need_num() { [[ "$2" =~ ^[0-9]+$ ]] || die "$1 requires a non-negative integer, got '$2'"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cpu|--mem|--disk|--load|--cpu-crit|--mem-crit|--disk-crit|--max-size|--keep)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      need_num "$1" "$2"
      case "$1" in
        --cpu) CPU_WARN=$2 ;;
        --mem) MEM_WARN=$2 ;;
        --disk) DISK_WARN=$2 ;;
        --load) LOAD_WARN=$2 ;;
        --cpu-crit) CPU_CRIT=$2 ;;
        --mem-crit) MEM_CRIT=$2 ;;
        --disk-crit) DISK_CRIT=$2 ;;
        --max-size) MAX_BYTES=$2 ;;
        --keep) KEEP=$2 ;;
      esac
      shift 2 ;;
    --log-file) [[ $# -ge 2 ]] || die "--log-file requires a value"; LOG_FILE=$2; shift 2 ;;
    --json) JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -V|--version) echo "$VERSION"; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

NCPU=$(nproc 2>/dev/null || echo 1)
[[ -n "$LOAD_WARN" ]] || LOAD_WARN=$((NCPU * 2))

# gt A B -> true if A > B (floating point safe)
gt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'; }

json_escape() {
  local s=${1//\\/\\\\}
  s=${s//\"/\\\"}
  printf '%s' "$s"
}

cpu_usage() {
  local u1 n1 s1 i1 w1 q1 sq1 st1 u2 n2 s2 i2 w2 q2 sq2 st2
  read -r _ u1 n1 s1 i1 w1 q1 sq1 st1 _ < /proc/stat
  sleep 1
  read -r _ u2 n2 s2 i2 w2 q2 sq2 st2 _ < /proc/stat
  local total=$(( (u2+n2+s2+i2+w2+q2+sq2+st2) - (u1+n1+s1+i1+w1+q1+sq1+st1) ))
  local idle=$(( (i2+w2) - (i1+w1) ))
  if (( total <= 0 )); then echo "0.0"; else
    awk -v t="$total" -v i="$idle" 'BEGIN { printf "%.1f", (t - i) * 100 / t }'
  fi
}

read -r MEM_TOTAL_KB MEM_AVAIL_KB < <(awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {print t, a}' /proc/meminfo)
MEM_PCT=$(awk -v t="$MEM_TOTAL_KB" -v a="$MEM_AVAIL_KB" 'BEGIN { printf "%.1f", (t - a) * 100 / t }')
CPU_PCT=$(cpu_usage)
read -r LOAD1 LOAD5 LOAD15 _ < /proc/loadavg
HOST=$(hostname)
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Disks: every real mounted filesystem (pseudo filesystems excluded).
DISK_MOUNTS=() DISK_PCTS=()
while read -r _ _ _ _ pct mount; do
  DISK_MOUNTS+=("$mount")
  DISK_PCTS+=("${pct%\%}")
done < <(df -P -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs 2>/dev/null | tail -n +2)

# Capture first, then trim: piping ps into head can SIGPIPE ps and trip pipefail.
PS_OUT=$(ps -eo pid=,comm=,%mem=,rss= --sort=-%mem)
TOP_PROCS=$(head -n 5 <<<"$PS_OUT")

# ---- Evaluate thresholds ----
STATUS=0
MESSAGES=()
flag() { # flag LEVEL(1|2) TEXT
  local label="WARNING"; [[ $1 -eq 2 ]] && label="CRITICAL"
  MESSAGES+=("[$label] $2")
  (( $1 > STATUS )) && STATUS=$1
  return 0
}
check() { # check NAME VALUE WARN CRIT UNIT
  if gt "$2" "$4"; then flag 2 "$1 is $2$5 (critical threshold $4$5)"
  elif gt "$2" "$3"; then flag 1 "$1 is $2$5 (threshold $3$5)"; fi
}
check "CPU usage" "$CPU_PCT" "$CPU_WARN" "$CPU_CRIT" "%"
check "Memory usage" "$MEM_PCT" "$MEM_WARN" "$MEM_CRIT" "%"
for i in "${!DISK_MOUNTS[@]}"; do
  check "Disk usage on ${DISK_MOUNTS[$i]}" "${DISK_PCTS[$i]}" "$DISK_WARN" "$DISK_CRIT" "%"
done
if gt "$LOAD1" "$LOAD_WARN"; then flag 1 "Load average (1m) is $LOAD1 (threshold $LOAD_WARN)"; fi

case $STATUS in 0) STATE="OK" ;; 1) STATE="WARNING" ;; *) STATE="CRITICAL" ;; esac

# ---- Render ----
render_json() {
  local i sep=""
  printf '{"timestamp":"%s","host":"%s","status":"%s","exit_code":%d,' "$TS" "$(json_escape "$HOST")" "$STATE" "$STATUS"
  printf '"cpu_pct":%s,"mem_pct":%s,"load":{"1m":%s,"5m":%s,"15m":%s},"disks":[' "$CPU_PCT" "$MEM_PCT" "$LOAD1" "$LOAD5" "$LOAD15"
  for i in "${!DISK_MOUNTS[@]}"; do
    printf '%s{"mount":"%s","used_pct":%s}' "$sep" "$(json_escape "${DISK_MOUNTS[$i]}")" "${DISK_PCTS[$i]}"; sep=","
  done
  printf '],"top_processes":['
  sep=""
  while read -r pid comm pmem rss; do
    printf '%s{"pid":%s,"command":"%s","mem_pct":%s,"rss_kb":%s}' "$sep" "$pid" "$(json_escape "$comm")" "$pmem" "$rss"; sep=","
  done <<<"$TOP_PROCS"
  printf '],"warnings":['
  sep=""
  for m in "${MESSAGES[@]+"${MESSAGES[@]}"}"; do printf '%s"%s"' "$sep" "$(json_escape "$m")"; sep=","; done
  printf ']}\n'
}

render_text() {
  local i disks=""
  for i in "${!DISK_MOUNTS[@]}"; do disks+="${DISK_MOUNTS[$i]}=${DISK_PCTS[$i]}% "; done
  echo "=== System health @ $TS on $HOST: $STATE ==="
  echo "CPU:    ${CPU_PCT}%"
  echo "Memory: ${MEM_PCT}% used"
  echo "Load:   $LOAD1 $LOAD5 $LOAD15 (1/5/15m, $NCPU CPUs)"
  echo "Disks:  ${disks% }"
  echo "Top 5 processes by memory (PID COMMAND %MEM RSS_KB):"
  while read -r line; do echo "  $line"; done <<<"$TOP_PROCS"
}

log_line_text() {
  local i disks=""
  for i in "${!DISK_MOUNTS[@]}"; do disks+="${DISK_MOUNTS[$i]}=${DISK_PCTS[$i]}%,"; done
  echo "$TS host=$HOST status=$STATE cpu=${CPU_PCT}% mem=${MEM_PCT}% load=$LOAD1 disks=${disks%,}"
}

rotate_log() {
  [[ -f "$LOG_FILE" ]] || return 0
  local size i
  size=$(stat -c %s "$LOG_FILE")
  (( size >= MAX_BYTES )) || return 0
  for (( i = KEEP - 1; i >= 1; i-- )); do
    if [[ -f "$LOG_FILE.$i" ]]; then mv -f "$LOG_FILE.$i" "$LOG_FILE.$((i + 1))"; fi
  done
  mv -f "$LOG_FILE" "$LOG_FILE.1"
}

notify() {
  [[ -n "$WEBHOOK_URL" && $STATUS -gt 0 ]] || return 0
  local text; text="$(json_escape "$HOST $STATE: ${MESSAGES[*]}")"
  # "text" is read by Slack, "content" by Discord.
  curl -fsS -m 10 -H 'Content-Type: application/json' \
    -d "{\"text\":\"$text\",\"content\":\"$text\"}" "$WEBHOOK_URL" >/dev/null \
    || echo "warning: webhook notification failed" >&2
}

mkdir -p "$(dirname "$LOG_FILE")"
exec 9>"$LOG_FILE.lock"
flock -w 10 9 || die "could not lock $LOG_FILE.lock"
rotate_log

if (( JSON )); then
  render_json | tee -a "$LOG_FILE"
  for m in "${MESSAGES[@]+"${MESSAGES[@]}"}"; do echo "$m" >&2; done
else
  render_text
  for m in "${MESSAGES[@]+"${MESSAGES[@]}"}"; do echo "$m"; done
  log_line_text >> "$LOG_FILE"
  for m in "${MESSAGES[@]+"${MESSAGES[@]}"}"; do echo "$TS $m" >> "$LOG_FILE"; done
fi

notify
exit "$STATUS"
