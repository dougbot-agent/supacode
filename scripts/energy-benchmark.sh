#!/usr/bin/env bash
set -euo pipefail

# Build Supacode first, then launch it with energy instrumentation enabled.
# This script intentionally does not automate private agent/model work; it gives
# repeatable local scenarios that exercise terminal rendering without dropping output.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${1:-$ROOT/docs/energy-logs}"
mkdir -p "$LOG_DIR"

cd "$ROOT"
COMMIT="$(git rev-parse --short HEAD)"
MACHINE="$(sysctl -n hw.model 2>/dev/null || uname -m)"
MACOS="$(sw_vers -productVersion) ($(sw_vers -buildVersion))"

cat >"$LOG_DIR/context-$COMMIT.txt" <<EOF
commit=$COMMIT
machine=$MACHINE
macos=$MACOS
scenario_log_dir=$LOG_DIR
EOF

cat >"$LOG_DIR/spinner-workload.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
frames='|/-\\'
end=$((SECONDS + ${SUPACODE_SPINNER_SECONDS:-60}))
while [ "$SECONDS" -lt "$end" ]; do
  for ((i=0; i<${#frames}; i++)); do
    printf '\r%s Thinking...' "${frames:i:1}"
    # 50 fps-ish spinner-only workload.
    perl -MTime::HiRes=usleep -e 'usleep(20000)'
  done
done
printf '\rDone thinking.        \n'
EOF
chmod +x "$LOG_DIR/spinner-workload.sh"

cat >"$LOG_DIR/stream-workload.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for i in $(seq 1 ${SUPACODE_STREAM_TOKENS:-1200}); do
  printf 'token-%04d ' "$i"
  if [ $((i % 12)) -eq 0 ]; then printf '\n'; fi
  perl -MTime::HiRes=usleep -e 'usleep(15000)'
done
EOF
chmod +x "$LOG_DIR/stream-workload.sh"

cat <<EOF
Energy benchmark assets written to: $LOG_DIR

Manual measurement recipe:
1. Baseline launch:
   SUPACODE_RENDER_STATS=1 make run-app 2>&1 | tee "$LOG_DIR/baseline-app.log"
2. In a Supacode terminal pane, run:
   "$LOG_DIR/spinner-workload.sh"
   "$LOG_DIR/stream-workload.sh"
3. Optimized launch:
   SUPACODE_RENDER_STATS=1 SUPACODE_ENERGY_MODE=1 make run-app 2>&1 | tee "$LOG_DIR/energy-mode-app.log"
4. Repeat the same workloads and compare render_stats lines:
   grep 'render_stats:' "$LOG_DIR"/*.log
5. Optional CPU sampling while the app is running:
   ps -A -o pid,comm | grep -i Supacode
   top -pid <PID> -stats pid,cpu,command -l 30 -s 1 | tee "$LOG_DIR/top-supacode.log"
EOF
