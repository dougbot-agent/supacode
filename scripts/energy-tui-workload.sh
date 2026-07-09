#!/usr/bin/env bash
set -euo pipefail

duration=60
workload="mixed"

usage() {
  cat <<'EOF'
Usage: scripts/energy-tui-workload.sh [--duration SECONDS] [--workload NAME]

Runs a deterministic terminal-rendering workload. It can run locally or inside
a Supacode tab.

Workloads:
  mixed            Progress reports, spinner/status, and streaming output
  progress-only    OSC 9;4 progress reports plus a small visible progress line
  spinner-status   Spinner/status-line churn without OSC progress reports
  stream-only      Streaming token output without progress or status redraws

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
    --workload)
      [ "$#" -ge 2 ] || fail "--workload requires a name"
      workload="$2"
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

case "${workload}" in
  mixed | progress-only | spinner-status | stream-only) ;;
  *) fail "unsupported workload: ${workload}. Supported workloads: mixed, progress-only, spinner-status, stream-only" ;;
esac

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

emit_progress_report() {
  percent="$1"
  printf '\033]9;4;1;%s\007' "${percent}"
}

clear_progress_report() {
  printf '\033]9;4;0;\007'
}

printf 'WORKLOAD_START duration=%s workload=%s\n' "${duration}" "${workload}"
printf 'WORKLOAD_READY\n'

start_epoch=$(date +%s)
end_epoch=$((start_epoch + duration))
tick=0
frames='|/-\'

emit_mixed_tick() {
  frame="$1"
  percent="$2"
  tick="$3"

  draw_progress "${percent}"
  emit_progress_report "${percent}"
  printf ' spinner=%s ' "${frame}"
  printf 'stream token-%04d token-%04d token-%04d token-%04d' \
    "$((tick * 4 + 1))" \
    "$((tick * 4 + 2))" \
    "$((tick * 4 + 3))" \
    "$((tick * 4 + 4))"
  printf '\n'
}

emit_progress_only_tick() {
  percent="$1"
  draw_progress "${percent}"
  emit_progress_report "${percent}"
  printf '\n'
}

emit_spinner_status_tick() {
  frame="$1"
  tick="$2"
  printf '\rphase=status spinner=%s heartbeat=%04d queue=%02d' \
    "${frame}" \
    "${tick}" \
    "$((tick % 17))"
}

emit_stream_only_tick() {
  tick="$1"
  printf 'stream token-%04d token-%04d token-%04d token-%04d\n' \
    "$((tick * 4 + 1))" \
    "$((tick * 4 + 2))" \
    "$((tick * 4 + 3))" \
    "$((tick * 4 + 4))"
}

while [ "$(date +%s)" -lt "${end_epoch}" ]; do
  frame_index=$((tick % 4))
  frame=$(printf '%s' "${frames}" | cut -c $((frame_index + 1)))
  elapsed=$(($(date +%s) - start_epoch))
  percent=$((elapsed * 100 / duration))
  [ "${percent}" -le 100 ] || percent=100

  case "${workload}" in
    mixed)
      emit_mixed_tick "${frame}" "${percent}" "${tick}"
      ;;
    progress-only)
      emit_progress_only_tick "${percent}"
      ;;
    spinner-status)
      emit_spinner_status_tick "${frame}" "${tick}"
      ;;
    stream-only)
      emit_stream_only_tick "${tick}"
      ;;
  esac

  tick=$((tick + 1))
  sleep_fraction 0.05
done

case "${workload}" in
  mixed | progress-only)
    draw_progress 100
    emit_progress_report 100
    clear_progress_report
    printf '\n'
    ;;
  spinner-status)
    printf '\n'
    ;;
  stream-only)
    ;;
esac
printf 'WORKLOAD_DONE ticks=%s workload=%s\n' "${tick}" "${workload}"
