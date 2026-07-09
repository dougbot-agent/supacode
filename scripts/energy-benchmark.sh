#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

app_path="${repo_root}/build/supacode/Build/Products/Debug/supacode.app"
cli_path=""
zmx_path=""
app_path_is_default=true
target_repo="${repo_root}"
output_dir="${repo_root}/docs/energy-logs/$(date +%Y%m%d-%H%M%S)"
repeat_count=3
duration_seconds=60
warmup_seconds=10
sample_interval=1
modes="baseline,low-energy"
powermetrics_mode="auto"
workload_name="mixed"
workload_state="focused-visible"
render_stats_mode="on"
use_persisted_setting=false
dry_run=false
timeout_seconds=20
workload_start_guard_seconds=5
workload_shell_settle_seconds=1

created_tab_id=""
session_id=""
worktree_id=""
started_pid=""
benchmark_socket_path=""
preexisting_sockets_path=""
preexisting_processes_path=""
settings_backup=""
settings_existed=false
current_run_dir=""
previous_render_stats_env=""
previous_energy_mode_env=""
previous_render_stats_file_env=""
launch_env_active=false

usage() {
  cat <<'EOF'
Usage: scripts/energy-benchmark.sh [options]

Runs baseline and low-energy Supacode energy benchmarks by launching an
instrumented app, injecting a deterministic TUI workload into a tab, collecting
CPU/render_stats logs, and writing summary reports.

Options:
  --app PATH                       .app path. Defaults to build/supacode/Build/Products/Debug/supacode.app
  --cli PATH                       supacode CLI path. Defaults to APP/Contents/Resources/bin/supacode
  --repo PATH                      Repo opened in Supacode. Defaults to current repo root
  --output-dir PATH                Output directory for this session
  --repeat N                       Runs per mode. Defaults to 3
  --duration SECONDS               Workload duration. Defaults to 60
  --warmup SECONDS                 Warmup before injection. Defaults to 10
  --sample-interval SECONDS        top/powermetrics sample interval. Defaults to 1
  --modes LIST                     Comma-separated modes. Defaults to baseline,low-energy
  --workload NAME                   Workload variant: mixed, progress-only, spinner-status, stream-only
  --state NAME                      Benchmark state metadata. Defaults to focused-visible
  --powermetrics auto|off|on       Defaults to auto; auto skips without prompting if unavailable
  --render-stats on|off             Defaults to on; off fails because E0 requires counter proof
  --use-persisted-setting          Fail clearly; env-flag path is the safe supported path
  --dry-run                        Print planned actions and exit 0 without requiring app bundle
  --help                           Show this help
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

note() {
  printf '==> %s\n' "$*"
}

is_positive_integer() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ "$1" -gt 0 ]
}

is_nonnegative_integer() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 0 ]
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app)
      [ "$#" -ge 2 ] || fail "--app requires a path"
      app_path="$2"
      app_path_is_default=false
      shift 2
      ;;
    --cli)
      [ "$#" -ge 2 ] || fail "--cli requires a path"
      cli_path="$2"
      shift 2
      ;;
    --repo)
      [ "$#" -ge 2 ] || fail "--repo requires a path"
      target_repo="$2"
      shift 2
      ;;
    --output-dir)
      [ "$#" -ge 2 ] || fail "--output-dir requires a path"
      output_dir="$2"
      shift 2
      ;;
    --repeat)
      [ "$#" -ge 2 ] || fail "--repeat requires a number"
      repeat_count="$2"
      shift 2
      ;;
    --duration)
      [ "$#" -ge 2 ] || fail "--duration requires seconds"
      duration_seconds="$2"
      shift 2
      ;;
    --warmup)
      [ "$#" -ge 2 ] || fail "--warmup requires seconds"
      warmup_seconds="$2"
      shift 2
      ;;
    --sample-interval)
      [ "$#" -ge 2 ] || fail "--sample-interval requires seconds"
      sample_interval="$2"
      shift 2
      ;;
    --modes)
      [ "$#" -ge 2 ] || fail "--modes requires a comma-separated list"
      modes="$2"
      shift 2
      ;;
    --powermetrics)
      [ "$#" -ge 2 ] || fail "--powermetrics requires auto, off, or on"
      powermetrics_mode="$2"
      shift 2
      ;;
    --workload)
      [ "$#" -ge 2 ] || fail "--workload requires a name"
      workload_name="$2"
      shift 2
      ;;
    --state)
      [ "$#" -ge 2 ] || fail "--state requires a name"
      workload_state="$2"
      shift 2
      ;;
    --render-stats)
      [ "$#" -ge 2 ] || fail "--render-stats requires on or off"
      render_stats_mode="$2"
      shift 2
      ;;
    --use-persisted-setting)
      use_persisted_setting=true
      shift
      ;;
    --dry-run)
      dry_run=true
      shift
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

workload_path="${script_dir}/energy-tui-workload.sh"

is_positive_integer "${repeat_count}" || fail "--repeat must be a positive integer"
is_positive_integer "${duration_seconds}" || fail "--duration must be a positive integer"
is_nonnegative_integer "${warmup_seconds}" || fail "--warmup must be a non-negative integer"
is_positive_integer "${sample_interval}" || fail "--sample-interval must be a positive integer"

case "${powermetrics_mode}" in
  auto | off | on) ;;
  *) fail "--powermetrics must be auto, off, or on" ;;
esac

case "${workload_name}" in
  mixed | progress-only | spinner-status | stream-only) ;;
  *) fail "unsupported workload: ${workload_name}. Supported workloads: mixed, progress-only, spinner-status, stream-only" ;;
esac

case "${render_stats_mode}" in
  on) ;;
  off) fail "--render-stats off cannot produce E0 counter proof; leave render stats enabled" ;;
  *) fail "--render-stats must be on or off" ;;
esac

if [ "${use_persisted_setting}" = true ]; then
  fail "--use-persisted-setting is not implemented safely yet; use the default env-flag mode instead. TODO: add atomic JSON mutation and restore."
fi

target_repo="$(cd "${target_repo}" && pwd)"

resolve_built_app_path() {
  command -v jq >/dev/null 2>&1 || return 1
  [ -d "${repo_root}/supacode.xcworkspace" ] || return 1

  developer_dir=""
  if [ -x "${repo_root}/scripts/select-developer-dir.sh" ]; then
    developer_dir="$("${repo_root}/scripts/select-developer-dir.sh" 2>/dev/null || true)"
  fi

  if [ -n "${developer_dir}" ]; then
    settings="$(DEVELOPER_DIR="${developer_dir}" xcodebuild -workspace "${repo_root}/supacode.xcworkspace" -scheme supacode -configuration Debug -showBuildSettings -json 2>/dev/null)" || return 1
  else
    settings="$(xcodebuild -workspace "${repo_root}/supacode.xcworkspace" -scheme supacode -configuration Debug -showBuildSettings -json 2>/dev/null)" || return 1
  fi

  build_dir="$(printf '%s' "${settings}" | jq -r '.[0].buildSettings.BUILT_PRODUCTS_DIR // empty')"
  product="$(printf '%s' "${settings}" | jq -r '.[0].buildSettings.FULL_PRODUCT_NAME // empty')"
  [ -n "${build_dir}" ] && [ -n "${product}" ] || return 1
  printf '%s/%s' "${build_dir}" "${product}"
}

if [ "${dry_run}" = false ] && [ "${app_path_is_default}" = true ] && [ ! -d "${app_path}" ]; then
  resolved_app_path="$(resolve_built_app_path || true)"
  if [ -n "${resolved_app_path}" ]; then
    app_path="${resolved_app_path}"
  fi
fi

[ -n "${cli_path}" ] || cli_path="${app_path}/Contents/Resources/bin/supacode"
[ -n "${zmx_path}" ] || zmx_path="${app_path}/Contents/Resources/zmx/zmx"

mode_env() {
  case "$1" in
    baseline)
      printf 'SUPACODE_RENDER_STATS=1 SUPACODE_ENERGY_WORKLOAD=%s SUPACODE_ENERGY_STATE=%s' "${workload_name}" "${workload_state}"
      ;;
    low-energy)
      printf 'SUPACODE_RENDER_STATS=1 SUPACODE_ENERGY_MODE=1 SUPACODE_ENERGY_WORKLOAD=%s SUPACODE_ENERGY_STATE=%s' "${workload_name}" "${workload_state}"
      ;;
    *)
      fail "unsupported mode: $1"
      ;;
  esac
}

mode_json_env() {
  case "$1" in
    baseline)
      printf '"SUPACODE_RENDER_STATS=1","SUPACODE_ENERGY_WORKLOAD=%s","SUPACODE_ENERGY_STATE=%s"' "${workload_name}" "${workload_state}"
      ;;
    low-energy)
      printf '"SUPACODE_RENDER_STATS=1","SUPACODE_ENERGY_MODE=1","SUPACODE_ENERGY_WORKLOAD=%s","SUPACODE_ENERGY_STATE=%s"' "${workload_name}" "${workload_state}"
      ;;
  esac
}

workload_uses_progress_reports() {
  case "${workload_name}" in
    mixed | progress-only) return 0 ;;
    *) return 1 ;;
  esac
}

normalize_list_lines() {
  awk '
    {
      escape = sprintf("%c", 27)
      gsub(escape "\\[[0-9;]*[[:alpha:]]", "")
      sub(/^[*] /, "")
      if (NF) {
        print
      }
    }
  '
}

first_list_id() {
  normalize_list_lines | awk 'NF { print; exit }'
}

list_ids() {
  normalize_list_lines
}

wait_for() {
  description="$1"
  shift

  deadline=$(($(date +%s) + timeout_seconds))
  while true; do
    if "$@"; then
      return 0
    fi
    if [ "$(date +%s)" -ge "${deadline}" ]; then
      fail "timed out waiting for ${description}"
    fi
    sleep 0.2
  done
}

run_dispatch_allow_timeout() {
  local description output status
  description="$1"
  shift

  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e

  printf '%s\n' "${output}" >>"${current_run_dir}/cli-dispatch.log"

  if [ "${status}" -eq 0 ]; then
    return 0
  fi

  if printf '%s\n' "${output}" | grep -F -q "Supacode is still loading. Try again."; then
    return 1
  fi

  if printf '%s\n' "${output}" | grep -F -q "Timed out waiting for response from Supacode."; then
    note "${description} did not answer within the CLI socket timeout; continuing to poll app state."
    return 0
  fi

  printf '%s\n' "${output}" >&2
  return "${status}"
}

run_cli() {
  if [ -n "${benchmark_socket_path}" ]; then
    SUPACODE_SOCKET_PATH="${benchmark_socket_path}" "${cli_path}" "$@"
    return
  fi
  "${cli_path}" "$@"
}

socket_count() {
  "${cli_path}" socket 2>/dev/null | awk 'NF { count++ } END { print count + 0 }'
}

write_socket_snapshot() {
  "${cli_path}" socket 2>/dev/null | normalize_list_lines >"$1" || : >"$1"
}

write_process_snapshot() {
  osascript -e 'tell application "System Events" to get unix id of every process whose name is "supacode"' 2>/dev/null \
    | tr ', ' '\n' \
    | awk 'NF' >"$1" || : >"$1"
}

capture_new_socket() {
  current_sockets="${current_run_dir}/current-sockets.txt"
  write_socket_snapshot "${current_sockets}"
  benchmark_socket_path="$(grep -F -x -v -f "${preexisting_sockets_path}" "${current_sockets}" | awk 'NF { print; exit }')"
  [ -n "${benchmark_socket_path}" ]
}

capture_started_process() {
  current_processes="${current_run_dir}/current-processes.txt"
  write_process_snapshot "${current_processes}"
  started_pid="$(grep -F -x -v -f "${preexisting_processes_path}" "${current_processes}" | awk 'NF { print; exit }')"
  [ -n "${started_pid}" ]
}

configure_launch_environment() {
  mode="$1"
  previous_render_stats_env="$(launchctl getenv SUPACODE_RENDER_STATS 2>/dev/null || true)"
  previous_energy_mode_env="$(launchctl getenv SUPACODE_ENERGY_MODE 2>/dev/null || true)"
  previous_render_stats_file_env="$(launchctl getenv SUPACODE_RENDER_STATS_FILE 2>/dev/null || true)"
  previous_energy_workload_env="$(launchctl getenv SUPACODE_ENERGY_WORKLOAD 2>/dev/null || true)"
  previous_energy_state_env="$(launchctl getenv SUPACODE_ENERGY_STATE 2>/dev/null || true)"
  render_stats_file="$(cd "$(dirname "${current_run_dir}/render-stats.log")" && pwd)/$(basename "${current_run_dir}/render-stats.log")"
  launchctl setenv SUPACODE_RENDER_STATS 1
  launchctl setenv SUPACODE_RENDER_STATS_FILE "${render_stats_file}"
  launchctl setenv SUPACODE_ENERGY_WORKLOAD "${workload_name}"
  launchctl setenv SUPACODE_ENERGY_STATE "${workload_state}"
  case "${mode}" in
    baseline)
      launchctl unsetenv SUPACODE_ENERGY_MODE
      ;;
    low-energy)
      launchctl setenv SUPACODE_ENERGY_MODE 1
      ;;
  esac
  launch_env_active=true
}

restore_launch_environment() {
  if [ "${launch_env_active}" != true ]; then
    return 0
  fi
  if [ -n "${previous_render_stats_env}" ]; then
    launchctl setenv SUPACODE_RENDER_STATS "${previous_render_stats_env}"
  else
    launchctl unsetenv SUPACODE_RENDER_STATS
  fi
  if [ -n "${previous_energy_mode_env}" ]; then
    launchctl setenv SUPACODE_ENERGY_MODE "${previous_energy_mode_env}"
  else
    launchctl unsetenv SUPACODE_ENERGY_MODE
  fi
  if [ -n "${previous_render_stats_file_env}" ]; then
    launchctl setenv SUPACODE_RENDER_STATS_FILE "${previous_render_stats_file_env}"
  else
    launchctl unsetenv SUPACODE_RENDER_STATS_FILE
  fi
  if [ -n "${previous_energy_workload_env:-}" ]; then
    launchctl setenv SUPACODE_ENERGY_WORKLOAD "${previous_energy_workload_env}"
  else
    launchctl unsetenv SUPACODE_ENERGY_WORKLOAD
  fi
  if [ -n "${previous_energy_state_env:-}" ]; then
    launchctl setenv SUPACODE_ENERGY_STATE "${previous_energy_state_env}"
  else
    launchctl unsetenv SUPACODE_ENERGY_STATE
  fi
  launch_env_active=false
}

benchmark_socket_stopped() {
  [ -n "${benchmark_socket_path}" ] || return 0
  [ ! -S "${benchmark_socket_path}" ]
}

capture_env_worktree() {
  [ -n "${SUPACODE_WORKTREE_ID:-}" ] || return 1
  worktree_id="${SUPACODE_WORKTREE_ID}"
  run_cli tab list --worktree "${worktree_id}" >/dev/null 2>&1
}

capture_focused_worktree() {
  output="$(run_cli worktree list --focused 2>/dev/null)" || return 1
  worktree_id="$(printf '%s\n' "${output}" | first_list_id)"
  [ -n "${worktree_id}" ]
  run_cli tab list --worktree "${worktree_id}" >/dev/null 2>&1
}

capture_target_worktree() {
  worktree_id="$(perl -MURI::Escape -e 'print uri_escape($ARGV[0])' "${target_repo}/")"
  [ -n "${worktree_id}" ]
  run_cli tab list --worktree "${worktree_id}" >/dev/null 2>&1
}

tab_exists() {
  output="$(run_cli tab list --worktree "${worktree_id}" 2>/dev/null)" || return 1
  printf '%s\n' "${output}" | list_ids | grep -F -q "${created_tab_id}"
}

session_exists() {
  [ -n "${session_id}" ] || return 1
  "${zmx_path}" ls 2>/dev/null | grep -F -q "${session_id}"
}

session_has_client() {
  [ -n "${session_id}" ] || return 1
  session_clients="$(
    "${zmx_path}" ls 2>/dev/null | awk -v session="${session_id}" '
      index($0, "name=" session) {
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^clients=/) {
            sub(/^clients=/, "", $i)
            print $i
            exit
          }
        }
      }
    '
  )"
  case "${session_clients}" in
    '' | *[!0-9]*)
      return 1
      ;;
  esac
  [ "${session_clients}" -gt 0 ]
}

start_app() {
  mode="$1"
  app_log="$2"

  [ -d "${app_path}" ] || fail "missing app bundle at ${app_path}. Run: make build-app"
  preexisting_sockets_path="${current_run_dir}/preexisting-sockets.txt"
  preexisting_processes_path="${current_run_dir}/preexisting-processes.txt"
  write_socket_snapshot "${preexisting_sockets_path}"
  write_process_snapshot "${preexisting_processes_path}"
  : >"${app_log}"
  printf 'Launched via LaunchServices open -n. Runtime logs are captured in render-stats.log.\n' >>"${app_log}"

  note "Launching ${mode} app process"
  configure_launch_environment "${mode}"
  open -n "${app_path}"
  wait_for "launched dev app process" capture_started_process
  wait_for "new Supacode socket for launched dev app" capture_new_socket
  restore_launch_environment
  printf 'pid=%s\n' "${started_pid}" >>"${app_log}"
  note "Using benchmark socket ${benchmark_socket_path}"
}

activate_started_app() {
  [ -n "${started_pid}" ] || return 1
  osascript <<EOF >/dev/null 2>&1
tell application "System Events"
  set appProcess to first process whose unix id is ${started_pid}
  set frontmost of appProcess to true
  if (count of windows of appProcess) is 0 then error "launched Supacode process has no visible windows"
  if frontmost of appProcess is not true then error "launched Supacode process is not frontmost"
end tell
EOF
}

stop_started_app() {
  if [ -n "${started_pid}" ]; then
    if kill -0 "${started_pid}" >/dev/null 2>&1; then
      kill "${started_pid}" >/dev/null 2>&1 || true
      wait "${started_pid}" >/dev/null 2>&1 || true
    fi
    started_pid=""
  fi
}

clear_benchmark_socket_file() {
  if [ -n "${benchmark_socket_path}" ]; then
    rm -f "${benchmark_socket_path}" >/dev/null 2>&1 || true
    benchmark_socket_path=""
  fi
}

cleanup() {
  status=$?
  if [ -n "${created_tab_id}" ] && [ -n "${worktree_id}" ] && [ -x "${cli_path}" ]; then
    run_cli tab close --worktree "${worktree_id}" --tab "${created_tab_id}" >/dev/null 2>&1 || true
  fi
  stop_started_app
  clear_benchmark_socket_file
  restore_launch_environment
  if [ -n "${settings_backup}" ]; then
    settings_path="${HOME}/.supacode/settings.json"
    if [ "${settings_existed}" = true ]; then
      cp "${settings_backup}" "${settings_path}" >/dev/null 2>&1 || true
    else
      rm -f "${settings_path}" >/dev/null 2>&1 || true
    fi
    rm -f "${settings_backup}" >/dev/null 2>&1 || true
  fi
  exit "${status}"
}
trap cleanup EXIT INT TERM

start_top_collector() {
  pid="$1"
  raw_path="$2"
  csv_path="$3"
  loops=$((duration_seconds + 3))
  loops=$((loops / sample_interval + 1))

  (
    top -pid "${pid}" -stats pid,cpu,command -l "${loops}" -s "${sample_interval}" >"${raw_path}" 2>&1
  ) &
  top_pid=$!
  printf 'sample,cpu\n' >"${csv_path}"
}

finish_top_collector() {
  raw_path="$1"
  csv_path="$2"
  if [ -n "${top_pid:-}" ]; then
    wait "${top_pid}" >/dev/null 2>&1 || true
    top_pid=""
  fi
  awk '
    /^ *[0-9]+[[:space:]]+[0-9.]+/ {
      sample++
      print sample "," $2
    }
  ' "${raw_path}" >>"${csv_path}" || true
}

start_render_stats_collector() {
  raw_path="$1"
  touch "${raw_path}"
  render_log_pid=""
}

finish_render_stats_collector() {
  if [ -n "${render_log_pid:-}" ]; then
    kill "${render_log_pid}" >/dev/null 2>&1 || true
    wait "${render_log_pid}" >/dev/null 2>&1 || true
    render_log_pid=""
  fi
}

powermetrics_available() {
  command -v powermetrics >/dev/null 2>&1 || return 1
  [ "$(id -u)" -eq 0 ] && return 0
  sudo -n true >/dev/null 2>&1
}

start_powermetrics_collector() {
  raw_path="$1"
  loops=$((duration_seconds + 3))
  loops=$((loops / sample_interval + 1))

  if [ "${powermetrics_mode}" = off ]; then
    : >"${raw_path}"
    powermetrics_pid=""
    return 0
  fi

  if ! powermetrics_available; then
    if [ "${powermetrics_mode}" = on ]; then
      fail "powermetrics requested but unavailable; run as root or configure noninteractive sudo"
    fi
    printf 'powermetrics skipped: unavailable without root/noninteractive sudo\n' >"${raw_path}"
    powermetrics_pid=""
    return 0
  fi

  interval_ms=$((sample_interval * 1000))
  if [ "$(id -u)" -eq 0 ]; then
    powermetrics --samplers tasks --show-process-energy -i "${interval_ms}" -n "${loops}" >"${raw_path}" 2>&1 &
  else
    sudo -n powermetrics --samplers tasks --show-process-energy -i "${interval_ms}" -n "${loops}" >"${raw_path}" 2>&1 &
  fi
  powermetrics_pid=$!
}

finish_powermetrics_collector() {
  if [ -n "${powermetrics_pid:-}" ]; then
    wait "${powermetrics_pid}" >/dev/null 2>&1 || true
    powermetrics_pid=""
  fi
}

mean_cpu_from_csv() {
  csv_path="$1"
  awk -F, 'NR > 1 && $2 != "" { sum += $2; count++ } END { if (count > 0) printf "%.4f", sum / count; else printf "" }' "${csv_path}"
}

render_stats_count() {
  render_log_path="$1"
  app_log_path="$2"
  awk '/render_stats:/ { count++ } END { print count + 0 }' "${render_log_path}" "${app_log_path}" 2>/dev/null || printf '0\n'
}

metric_activity_seen() {
  metric_name="$1"
  render_log_path="$2"
  app_log_path="$3"
  awk -v metric="${metric_name}" '
    index($0, metric "=") > 0 {
      value = $0
      sub("^.*" metric "=", "", value)
      sub(/ .*$/, "", value)
      if (value + 0 > 0) {
        found = 1
      }
    }
    END { exit found ? 0 : 1 }
  ' "${render_log_path}" "${app_log_path}" 2>/dev/null
}

render_stats_proof_seen() {
  render_log_path="$1"
  app_log_path="$2"
  awk '
    /render_stats:/ && index($0, "render_counter_source=appkit_proxy") > 0 && index($0, "workload=") > 0 && index($0, "state=") > 0 {
      source_seen = 1
    }
    /render_stats:/ && index($0, "presentation_requests_per_s=") > 0 {
      requests_seen = 1
    }
    /render_stats:/ && index($0, "committed_frame_proxies_per_s=") > 0 {
      commits_seen = 1
    }
    /render_stats:/ && index($0, "coalesced_frame_proxies_per_s=") > 0 {
      coalesced_seen = 1
    }
    END { exit (source_seen && requests_seen && commits_seen && coalesced_seen) ? 0 : 1 }
  ' "${render_log_path}" "${app_log_path}" 2>/dev/null
}

run_workload_tab() {
  workload_duration="$1"
  created_tab_id="$(uuidgen)"
  session_id="supa-$(printf '%s' "${created_tab_id}" | tr '[:upper:]' '[:lower:]')"
  note "Creating tab ${created_tab_id} in worktree ${worktree_id}"
  run_dispatch_allow_timeout "tab new" run_cli tab new --worktree "${worktree_id}" --id "${created_tab_id}" --input $'\n'
  wait_for "created tab ${created_tab_id}" tab_exists
  wait_for "zmx session ${session_id}" session_exists
  wait_for "zmx attached client for ${session_id}" session_has_client
  sleep "${workload_shell_settle_seconds}"
  note "Submitting workload to tab ${created_tab_id}"
  "${zmx_path}" run "${session_id}" "${workload_path}" --duration "${workload_duration}" --workload "${workload_name}" >>"${current_run_dir}/cli-dispatch.log" 2>&1 &
}

close_workload_tab() {
  if [ -n "${created_tab_id}" ] && [ -n "${worktree_id}" ]; then
    note "Closing tab ${created_tab_id}"
    run_cli tab close --worktree "${worktree_id}" --tab "${created_tab_id}" >/dev/null 2>&1 || true
    created_tab_id=""
    session_id=""
  fi
}

write_context() {
  mkdir -p "${output_dir}"
  commit="$(git -C "${repo_root}" rev-parse --short HEAD 2>/dev/null || printf unknown)"
  machine="$(sysctl -n hw.model 2>/dev/null || uname -m)"
  macos="$(sw_vers -productVersion 2>/dev/null || printf unknown) ($(sw_vers -buildVersion 2>/dev/null || printf unknown))"
  cat >"${output_dir}/context.txt" <<EOF
commit=${commit}
machine=${machine}
macos=${macos}
repo=${target_repo}
app=${app_path}
cli=${cli_path}
zmx=${zmx_path}
repeat=${repeat_count}
duration=${duration_seconds}
warmup=${warmup_seconds}
sample_interval=${sample_interval}
workload_duration=$((duration_seconds + workload_start_guard_seconds))
workload_shell_settle=${workload_shell_settle_seconds}
modes=${modes}
workload=${workload_name}
state=${workload_state}
powermetrics=${powermetrics_mode}
EOF
}

dry_run_plan() {
  workload_command="${workload_path} --duration $((duration_seconds + workload_start_guard_seconds)) --workload ${workload_name}"
  cat <<EOF
Energy benchmark dry-run plan
app: ${app_path}
cli: ${cli_path}
repo: ${target_repo}
output_dir: ${output_dir}
repeat: ${repeat_count}
duration: ${duration_seconds}
warmup: ${warmup_seconds}
sample_interval: ${sample_interval}
modes: ${modes}
powermetrics: ${powermetrics_mode}
workload: ${workload_name}
state: ${workload_state}
workload command: ${workload_command}
summary csv: ${output_dir}/summary.csv
summary jsonl: ${output_dir}/summary.jsonl
report: ${output_dir}/report.md
EOF

  old_ifs="${IFS}"
  IFS=','
  for mode in ${modes}; do
    IFS="${old_ifs}"
    env_text="$(mode_env "${mode}")"
    run_index=1
    while [ "${run_index}" -le "${repeat_count}" ]; do
      run_dir="${output_dir}/${mode}/run-${run_index}"
      cat <<EOF
mode ${mode} run ${run_index} env: ${env_text}
mode ${mode} run ${run_index} launch app bundle with LaunchServices: ${app_path}
mode ${mode} run ${run_index} socket binding: launch dev app, detect new socket, set SUPACODE_SOCKET_PATH=<new-socket> for CLI calls
mode ${mode} run ${run_index} visibility: require launched dev app window count > 0 and frontmost before sampling
mode ${mode} run ${run_index} repo open action: ${cli_path} repo open ${target_repo}
mode ${mode} run ${run_index} worktree target: percent-encoded ${target_repo}/
mode ${mode} run ${run_index} tab open action: ${cli_path} tab new --worktree <focused-worktree> --id <uuidgen> --input '<newline>'
mode ${mode} run ${run_index} tab readiness: wait for zmx session, attached client, and ${workload_shell_settle_seconds}s shell settle
mode ${mode} run ${run_index} workload submit action: ${zmx_path} run <session> ${workload_command}
mode ${mode} run ${run_index} tab close action: ${cli_path} tab close --worktree <focused-worktree> --tab <uuid>
mode ${mode} run ${run_index} collectors: ${run_dir}/cpu.csv ${run_dir}/top.log ${run_dir}/render-stats.log ${run_dir}/powermetrics.log
EOF
      run_index=$((run_index + 1))
    done
    IFS=','
  done
  IFS="${old_ifs}"
}

if [ "${dry_run}" = true ]; then
  dry_run_plan
  exit 0
fi

[ -d "${app_path}" ] || fail "missing app bundle at ${app_path}. Run: make build-app"
[ -x "${cli_path}" ] || fail "missing executable CLI at ${cli_path}. Run: make build-app"
[ -x "${zmx_path}" ] || fail "missing executable zmx at ${zmx_path}. Run: make build-app"
[ -x "${workload_path}" ] || fail "missing executable workload at ${workload_path}"

write_context
summary_csv="${output_dir}/summary.csv"
summary_jsonl="${output_dir}/summary.jsonl"
report_path="${output_dir}/report.md"
printf 'mode,workload,state,run,mean_cpu,render_stats_count,render_stats_proof,powermetrics_collected,run_dir\n' >"${summary_csv}"
: >"${summary_jsonl}"

old_ifs="${IFS}"
IFS=','
for mode in ${modes}; do
  IFS="${old_ifs}"
  mode_env "${mode}" >/dev/null
  run_index=1
  while [ "${run_index}" -le "${repeat_count}" ]; do
    current_run_dir="${output_dir}/${mode}/run-${run_index}"
    mkdir -p "${current_run_dir}"
    : >"${current_run_dir}/cli-dispatch.log"

    note "Starting ${mode} run ${run_index}/${repeat_count}"
    start_app "${mode}" "${current_run_dir}/app.log"
    sleep "${warmup_seconds}"

    wait_for "repo open to be accepted" run_dispatch_allow_timeout "repo open" run_cli repo open "${target_repo}"
    wait_for "target worktree after repo open" capture_target_worktree
    wait_for "launched dev app window to become frontmost" activate_started_app

    start_render_stats_collector "${current_run_dir}/render-stats.log"

    workload_duration="$((duration_seconds + workload_start_guard_seconds))"
    run_workload_tab "${workload_duration}"
    if workload_uses_progress_reports; then
      wait_for "OSC 9;4 progress reports from workload" \
        metric_activity_seen "progress_reports_per_s" "${current_run_dir}/render-stats.log" "${current_run_dir}/app.log"
    else
      wait_for "render stats proof counters from workload" \
        render_stats_proof_seen "${current_run_dir}/render-stats.log" "${current_run_dir}/app.log"
    fi
    start_top_collector "${started_pid}" "${current_run_dir}/top.log" "${current_run_dir}/cpu.csv"
    start_powermetrics_collector "${current_run_dir}/powermetrics.log"
    sleep "${duration_seconds}"
    close_workload_tab

    finish_top_collector "${current_run_dir}/top.log" "${current_run_dir}/cpu.csv"
    finish_render_stats_collector
    finish_powermetrics_collector

    if ! render_stats_proof_seen "${current_run_dir}/render-stats.log" "${current_run_dir}/app.log"; then
      fail "render stats proof counters were not observed in ${current_run_dir}/render-stats.log"
    fi
    if workload_uses_progress_reports; then
      if ! metric_activity_seen "progress_reports_per_s" "${current_run_dir}/render-stats.log" "${current_run_dir}/app.log"; then
        fail "OSC 9;4 progress reports were not observed in ${current_run_dir}/render-stats.log"
      fi
      if ! metric_activity_seen "progress_applies_per_s" "${current_run_dir}/render-stats.log" "${current_run_dir}/app.log"; then
        fail "progress applies were not observed in ${current_run_dir}/render-stats.log"
      fi
    fi

    mean_cpu="$(mean_cpu_from_csv "${current_run_dir}/cpu.csv")"
    render_count="$(render_stats_count "${current_run_dir}/render-stats.log" "${current_run_dir}/app.log")"
    powermetrics_collected=false
    if [ -s "${current_run_dir}/powermetrics.log" ] && ! grep -F -q 'powermetrics skipped:' "${current_run_dir}/powermetrics.log"; then
      powermetrics_collected=true
    fi

    render_stats_proof=true
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "${mode}" "${workload_name}" "${workload_state}" "${run_index}" "${mean_cpu}" "${render_count}" "${render_stats_proof}" "${powermetrics_collected}" "${current_run_dir}" >>"${summary_csv}"
    printf '{"mode":"%s","workload":"%s","state":"%s","run":%s,"mean_cpu":%s,"render_stats_count":%s,"render_stats_proof":%s,"powermetrics_collected":%s,"run_dir":"%s","env":[%s]}\n' \
      "${mode}" "${workload_name}" "${workload_state}" "${run_index}" "${mean_cpu:-null}" "${render_count}" "${render_stats_proof}" "${powermetrics_collected}" "${current_run_dir}" "$(mode_json_env "${mode}")" >>"${summary_jsonl}"

    stop_started_app
    clear_benchmark_socket_file
    run_index=$((run_index + 1))
  done
  IFS=','
done
IFS="${old_ifs}"

baseline_mean="$(awk -F, '$1 == "baseline" && $5 != "" { sum += $5; count++ } END { if (count > 0) printf "%.4f", sum / count }' "${summary_csv}")"
low_energy_mean="$(awk -F, '$1 == "low-energy" && $5 != "" { sum += $5; count++ } END { if (count > 0) printf "%.4f", sum / count }' "${summary_csv}")"
reduction=""
target_status="unavailable"
if [ -n "${baseline_mean}" ] && [ -n "${low_energy_mean}" ]; then
  reduction="$(awk -v base="${baseline_mean}" -v low="${low_energy_mean}" 'BEGIN { if (base > 0) printf "%.2f", ((base - low) / base) * 100 }')"
  if awk -v value="${reduction}" 'BEGIN { exit !(value >= 75) }'; then
    target_status="passed"
  else
    target_status="failed"
  fi
fi

cat >"${report_path}" <<EOF
# Supacode Energy Benchmark

- Output: ${output_dir}
- Workload: ${workload_name}
- State: ${workload_state}
- Baseline mean CPU: ${baseline_mean:-unavailable}
- Low-energy mean CPU: ${low_energy_mean:-unavailable}
- Mean CPU reduction: ${reduction:-unavailable}%
- 75% target: ${target_status}

Raw logs are preserved in each per-run directory.
EOF

note "Wrote summary: ${summary_csv}"
note "Wrote report: ${report_path}"
