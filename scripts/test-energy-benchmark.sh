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

assert_not_contains() {
  file_path="$1"
  needle="$2"
  if grep -F -q -- "${needle}" "${file_path}"; then
    printf 'unexpected text: %s\n' "${needle}" >&2
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
for workload in mixed progress-only spinner-status stream-only; do
  workload_log="${TMPDIR:-/tmp}/supacode-energy-workload-${workload}-test.log"
  "${workload_script}" --duration 1 --workload "${workload}" >"${workload_log}"
  assert_contains "${workload_log}" "WORKLOAD_START duration=1 workload=${workload}"
  assert_contains "${workload_log}" "WORKLOAD_READY"
  assert_contains "${workload_log}" "WORKLOAD_DONE"
  assert_contains "${workload_log}" "workload=${workload}"
done

assert_contains "${TMPDIR:-/tmp}/supacode-energy-workload-mixed-test.log" "$(printf '\033]9;4;1;')"
assert_contains "${TMPDIR:-/tmp}/supacode-energy-workload-mixed-test.log" "$(printf '\033]9;4;0;\007')"
assert_contains "${TMPDIR:-/tmp}/supacode-energy-workload-progress-only-test.log" "$(printf '\033]9;4;1;')"
assert_not_contains "${TMPDIR:-/tmp}/supacode-energy-workload-spinner-status-test.log" "$(printf '\033]9;4;1;')"
assert_not_contains "${TMPDIR:-/tmp}/supacode-energy-workload-stream-only-test.log" "$(printf '\033]9;4;1;')"

unsupported_workload_log="${TMPDIR:-/tmp}/supacode-energy-workload-unsupported-test.log"
if "${workload_script}" --duration 1 --workload nope >"${unsupported_workload_log}" 2>&1; then
  fail "unsupported workload succeeded"
fi
assert_contains "${unsupported_workload_log}" "unsupported workload: nope"

note "Dry-run assertions"
dry_run_log="${TMPDIR:-/tmp}/supacode-energy-benchmark-dry-run.log"
before_stat=""
if [ -e "${HOME}/.supacode/settings.json" ]; then
  before_stat="$(stat -f '%m %z' "${HOME}/.supacode/settings.json" 2>/dev/null || true)"
fi
"${benchmark_script}" --dry-run --repeat 1 --duration 2 --warmup 1 --powermetrics off --workload progress-only --state focused-visible --output-dir "${TMPDIR:-/tmp}/supacode-energy-dry-run" >"${dry_run_log}"
assert_contains "${dry_run_log}" "Energy benchmark dry-run plan"
assert_contains "${dry_run_log}" "workload: progress-only"
assert_contains "${dry_run_log}" "state: focused-visible"
assert_contains "${dry_run_log}" "mode baseline run 1 env: SUPACODE_RENDER_STATS=1 SUPACODE_ENERGY_WORKLOAD=progress-only SUPACODE_ENERGY_STATE=focused-visible"
assert_contains "${dry_run_log}" "mode low-energy run 1 env: SUPACODE_RENDER_STATS=1 SUPACODE_ENERGY_MODE=1 SUPACODE_ENERGY_WORKLOAD=progress-only SUPACODE_ENERGY_STATE=focused-visible"
assert_contains "${dry_run_log}" "benchmark state action: apply focused-visible before sampling"
assert_contains "${dry_run_log}" "tab open action:"
assert_contains "${dry_run_log}" "--id <uuidgen>"
assert_contains "${dry_run_log}" "tab readiness: wait for zmx session"
assert_contains "${dry_run_log}" "workload submit action:"
assert_contains "${dry_run_log}" "--workload progress-only"
assert_contains "${dry_run_log}" "zmx"
assert_contains "${dry_run_log}" "run <session>"
assert_contains "${dry_run_log}" "<newline>"
assert_contains "${dry_run_log}" "tab close action:"
assert_contains "${dry_run_log}" "--tab <uuid>"
assert_contains "${dry_run_log}" "summary csv:"
assert_contains "${dry_run_log}" "summary jsonl:"
assert_contains "${dry_run_log}" "comparison csv:"
assert_contains "${dry_run_log}" "comparison jsonl:"
assert_contains "${dry_run_log}" "render-stats.log"

focused_active_dry_run_log="${TMPDIR:-/tmp}/supacode-energy-benchmark-focused-active-dry-run.log"
"${benchmark_script}" --dry-run --repeat 1 --duration 2 --warmup 1 --powermetrics off --workload mixed --state focused-active --output-dir "${TMPDIR:-/tmp}/supacode-energy-focused-active-dry-run" >"${focused_active_dry_run_log}"
assert_contains "${focused_active_dry_run_log}" "state: focused-active"
assert_contains "${focused_active_dry_run_log}" "focused-active keeps the terminal interactive"
assert_contains "${focused_active_dry_run_log}" "active keepalive: focused-active sends control-u through surface focus every 0.25s"

stale_output_dir="${TMPDIR:-/tmp}/supacode-energy-stale-report-test"
rm -rf "${stale_output_dir}"
mkdir -p "${stale_output_dir}"
printf -- '- Mean appkit proxy frame reduction vs requests: 99.99%%\n' >"${stale_output_dir}/report.md"
failed_report_log="${TMPDIR:-/tmp}/supacode-energy-stale-report-test.log"
if "${benchmark_script}" --repeat 1 --duration 2 --warmup 1 --powermetrics off --workload progress-only --state focused-visible --output-dir "${stale_output_dir}" --app "${TMPDIR:-/tmp}/missing-supacode.app" >"${failed_report_log}" 2>&1; then
  fail "benchmark with missing app succeeded"
fi
assert_contains "${failed_report_log}" "missing app bundle"
assert_not_contains "${stale_output_dir}/report.md" "99.99%"
assert_contains "${stale_output_dir}/report.md" "Status: failed"
assert_contains "${stale_output_dir}/report.md" "Comparison CSV: unavailable"
assert_contains "${stale_output_dir}/report.md" "Direct committed appkit proxy reduction: unavailable%"
assert_contains "${stale_output_dir}/report.md" "No successful report was produced because the benchmark exited before complete CSV/JSONL rows were written."
assert_contains "${stale_output_dir}/summary.csv" "mode,workload,state,run"
[ "$(awk 'END { print NR + 0 }' "${stale_output_dir}/summary.csv")" -eq 1 ] || fail "failed summary.csv contains data rows"
[ ! -s "${stale_output_dir}/summary.jsonl" ] || fail "failed summary.jsonl contains rows"
assert_contains "${stale_output_dir}/comparison.csv" "workload,state,baseline_mean_cpu,low_energy_mean_cpu,direct_cpu_reduction_percent"
[ "$(awk 'END { print NR + 0 }' "${stale_output_dir}/comparison.csv")" -eq 1 ] || fail "failed comparison.csv contains data rows"
[ ! -s "${stale_output_dir}/comparison.jsonl" ] || fail "failed comparison.jsonl contains rows"

background_dry_run_log="${TMPDIR:-/tmp}/supacode-energy-benchmark-background-dry-run.log"
"${benchmark_script}" --dry-run --repeat 1 --duration 2 --warmup 1 --powermetrics off --workload progress-only --state background-unfocused --output-dir "${TMPDIR:-/tmp}/supacode-energy-background-dry-run" >"${background_dry_run_log}"
assert_contains "${background_dry_run_log}" "state: background-unfocused"
assert_contains "${background_dry_run_log}" "benchmark state action: apply background-unfocused before sampling"

hidden_dry_run_log="${TMPDIR:-/tmp}/supacode-energy-benchmark-hidden-dry-run.log"
"${benchmark_script}" --dry-run --repeat 1 --duration 2 --warmup 1 --powermetrics off --workload progress-only --state occluded-hidden --output-dir "${TMPDIR:-/tmp}/supacode-energy-hidden-dry-run" >"${hidden_dry_run_log}"
assert_contains "${hidden_dry_run_log}" "state: occluded-hidden"
assert_contains "${hidden_dry_run_log}" "benchmark state action: apply occluded-hidden before sampling"

unsupported_benchmark_log="${TMPDIR:-/tmp}/supacode-energy-benchmark-unsupported-test.log"
if "${benchmark_script}" --dry-run --workload nope >"${unsupported_benchmark_log}" 2>&1; then
  fail "unsupported benchmark workload succeeded"
fi
assert_contains "${unsupported_benchmark_log}" "unsupported workload: nope"

render_stats_off_log="${TMPDIR:-/tmp}/supacode-energy-benchmark-render-stats-off-test.log"
if "${benchmark_script}" --dry-run --render-stats off >"${render_stats_off_log}" 2>&1; then
  fail "render-stats off benchmark succeeded"
fi
assert_contains "${render_stats_off_log}" "cannot produce E0 counter proof"

if [ -e "${HOME}/.supacode/settings.json" ]; then
  after_stat="$(stat -f '%m %z' "${HOME}/.supacode/settings.json" 2>/dev/null || true)"
  [ "${before_stat}" = "${after_stat}" ] || fail "settings.json changed during dry-run test"
fi

note "PASS: energy benchmark non-GUI checks passed"
