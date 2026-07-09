#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() {
  echo "error: $*" >&2
  exit 1
}

note() {
  printf '==> %s\n' "$*"
}

assert_contains() {
  file_path="$1"
  needle="$2"
  if ! grep -F -q -- "${needle}" "${file_path}"; then
    printf 'missing expected text: %s\n' "${needle}" >&2
    printf '--- %s ---\n' "${file_path}" >&2
    cat "${file_path}" >&2
    fail "assertion failed"
  fi
}

benchmark_script="${script_dir}/energy-benchmark.sh"
workload_script="${script_dir}/energy-tui-workload.sh"

note "Syntax checks"
bash -n "${benchmark_script}" "${workload_script}" "$0"

note "Workload smoke"
workload_log="${TMPDIR:-/tmp}/supacode-energy-workload-test.log"
"${workload_script}" --duration 1 >"${workload_log}"
assert_contains "${workload_log}" "WORKLOAD_START duration=1"
assert_contains "${workload_log}" "WORKLOAD_READY"
assert_contains "${workload_log}" "WORKLOAD_DONE"
assert_contains "${workload_log}" "$(printf '\033]9;4;1;')"
assert_contains "${workload_log}" "$(printf '\033]9;4;0;\007')"

note "Dry-run assertions"
dry_run_log="${TMPDIR:-/tmp}/supacode-energy-benchmark-dry-run.log"
before_stat=""
if [ -e "${HOME}/.supacode/settings.json" ]; then
  before_stat="$(stat -f '%m %z' "${HOME}/.supacode/settings.json" 2>/dev/null || true)"
fi
"${benchmark_script}" --dry-run --repeat 1 --duration 2 --warmup 1 --powermetrics off --output-dir "${TMPDIR:-/tmp}/supacode-energy-dry-run" >"${dry_run_log}"
assert_contains "${dry_run_log}" "Energy benchmark dry-run plan"
assert_contains "${dry_run_log}" "mode baseline run 1 env: SUPACODE_RENDER_STATS=1"
assert_contains "${dry_run_log}" "mode low-energy run 1 env: SUPACODE_RENDER_STATS=1 SUPACODE_ENERGY_MODE=1"
assert_contains "${dry_run_log}" "tab open action:"
assert_contains "${dry_run_log}" "--id <uuidgen>"
assert_contains "${dry_run_log}" "tab readiness: wait for zmx session"
assert_contains "${dry_run_log}" "workload submit action:"
assert_contains "${dry_run_log}" "zmx"
assert_contains "${dry_run_log}" "run <session>"
assert_contains "${dry_run_log}" "<newline>"
assert_contains "${dry_run_log}" "tab close action:"
assert_contains "${dry_run_log}" "--tab <uuid>"
assert_contains "${dry_run_log}" "summary csv:"
assert_contains "${dry_run_log}" "render-stats.log"

if [ -e "${HOME}/.supacode/settings.json" ]; then
  after_stat="$(stat -f '%m %z' "${HOME}/.supacode/settings.json" 2>/dev/null || true)"
  [ "${before_stat}" = "${after_stat}" ] || fail "settings.json changed during dry-run test"
fi

note "PASS: energy benchmark non-GUI checks passed"
