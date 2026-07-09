#!/usr/bin/env bash
set -euo pipefail

duration=60

usage() {
  cat <<'EOF'
Usage: scripts/energy-tui-workload.sh [--duration SECONDS]

Runs a deterministic terminal-rendering workload with progress bars, spinners,
and streaming output. It can run locally or inside a Supacode tab.

Markers:
  WORKLOAD_START
  WORKLOAD_READY
  WORKLOAD_DONE
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --duration)
      [ "$#" -ge 2 ] || fail "--duration requires seconds"
      duration="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

case "${duration}" in
  '' | *[!0-9]*)
    fail "--duration must be a positive integer"
    ;;
esac
[ "${duration}" -gt 0 ] || fail "--duration must be greater than zero"

sleep_fraction() {
  perl -MTime::HiRes=usleep -e 'usleep(int($ARGV[0] * 1000000))' "$1"
}

draw_progress() {
  percent="$1"
  filled=$((percent / 5))
  empty=$((20 - filled))
  bar=""
  while [ "${filled}" -gt 0 ]; do
    bar="${bar}#"
    filled=$((filled - 1))
  done
  while [ "${empty}" -gt 0 ]; do
    bar="${bar}."
    empty=$((empty - 1))
  done
  printf '\rphase=render progress=[%s] %3d%%' "${bar}" "${percent}"
}

printf 'WORKLOAD_START duration=%s\n' "${duration}"
printf 'WORKLOAD_READY\n'

start_epoch=$(date +%s)
end_epoch=$((start_epoch + duration))
tick=0
frames='|/-\'

while [ "$(date +%s)" -lt "${end_epoch}" ]; do
  frame_index=$((tick % 4))
  frame=$(printf '%s' "${frames}" | cut -c $((frame_index + 1)))
  elapsed=$(($(date +%s) - start_epoch))
  percent=$((elapsed * 100 / duration))
  [ "${percent}" -le 100 ] || percent=100

  draw_progress "${percent}"
  printf ' spinner=%s ' "${frame}"
  printf 'stream token-%04d token-%04d token-%04d token-%04d' \
    "$((tick * 4 + 1))" \
    "$((tick * 4 + 2))" \
    "$((tick * 4 + 3))" \
    "$((tick * 4 + 4))"
  printf '\n'

  tick=$((tick + 1))
  sleep_fraction 0.05
done

draw_progress 100
printf '\nWORKLOAD_DONE ticks=%s\n' "${tick}"
