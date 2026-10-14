#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

OUTPUT_DIR="/tmp/wattsci"
BASELINE_DIR="$OUTPUT_DIR/baseline"

VARS_SCRIPT="$SCRIPT_DIR/vars.sh"
VARS_FILE="$OUTPUT_DIR/vars.sh"

PID_FILE="$OUTPUT_DIR/measurement.pid"
BASELINE_PID_FILE="$BASELINE_DIR/measurement.pid"

TIMER_FILE_START="$OUTPUT_DIR/timer_start.txt"
TIMER_FILE_END="$OUTPUT_DIR/timer_end.txt"
TIMER_FILE_BASELINE_START="$BASELINE_DIR/start.txt"
TIMER_FILE_BASELINE_END="$BASELINE_DIR/end.txt"

PERF_OUTPUT_FILE="$OUTPUT_DIR/data.txt"
PERF_BASELINE_FILE="$BASELINE_DIR/data.txt"
TOOL_LOG_FILE="$OUTPUT_DIR/perf.log"

# --------------------------------------------------
# Logging
# --------------------------------------------------

log() {
    printf '[measurement] %s\n' "$*"
}

die() {
    printf '[measurement] ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    echo "Usage: $0 --config <config_file> --action <action>"
    echo "Actions: start_measurement, stop_measurement,"
    echo "         baseline_measurement, stop_baseline_measurement"
    exit 1
}

# --------------------------------------------------
# Arguments
# --------------------------------------------------

CONFIG_FILE=""
ACTION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            [[ $# -ge 2 ]] || usage
            CONFIG_FILE="$2"
            shift 2
            ;;
        --action)
            [[ $# -ge 2 ]] || usage
            ACTION="$2"
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done

[[ -n "$CONFIG_FILE" && -n "$ACTION" ]] || usage
[[ -f "$CONFIG_FILE" ]] || die "Config not found: $CONFIG_FILE"

mkdir -p "$OUTPUT_DIR" "$BASELINE_DIR"

CONFIG_FILE="$(realpath -- "$CONFIG_FILE")"
CONFIG_FILENAME="$(basename -- "$CONFIG_FILE")"
cp -- "$CONFIG_FILE" "$OUTPUT_DIR/$CONFIG_FILENAME"

# --------------------------------------------------
# CI variables
# vars.sh defines add_var and initialize_vars.
# The variable values are written to /tmp/wattsci/vars.sh.
# --------------------------------------------------

if [[ -f "$VARS_SCRIPT" ]]; then
    source "$VARS_SCRIPT"

    if declare -F initialize_vars >/dev/null &&
       declare -F add_var >/dev/null; then

        initialize_vars

        if [[ -n "${GITHUB_RUN_ID:-}" ]]; then
            add_var CI "GitHub"
            add_var RUN_ID "${GITHUB_RUN_ID}"
            add_var REF_NAME "${GITHUB_REF_NAME:-unknown}"
            add_var REPOSITORY "${GITHUB_REPOSITORY:-unknown}"
            add_var WORKFLOW_ID "${GITHUB_WORKFLOW:-unknown}"
            add_var WORKFLOW_NAME "${GITHUB_WORKFLOW:-unknown}"
            add_var COMMIT_HASH "${GITHUB_SHA:-unknown}"

        elif [[ -n "${CI_PIPELINE_ID:-}" ]]; then
            add_var CI "GitLab"
            add_var RUN_ID "${CI_PIPELINE_ID}"
            add_var REF_NAME "${CI_COMMIT_REF_NAME:-unknown}"
            add_var REPOSITORY "${CI_PROJECT_PATH:-unknown}"
            add_var WORKFLOW_ID "${CI_JOB_ID:-unknown}"
            add_var WORKFLOW_NAME "${CI_JOB_NAME:-unknown}"
            add_var COMMIT_HASH "${CI_COMMIT_SHA:-unknown}"

        elif [[ -n "${BITBUCKET_BUILD_NUMBER:-}" ]]; then
            add_var CI "Bitbucket"
            add_var RUN_ID "${BITBUCKET_BUILD_NUMBER}"
            add_var REF_NAME "${BITBUCKET_BRANCH:-unknown}"
            add_var REPOSITORY "${BITBUCKET_REPO_SLUG:-unknown}"
            add_var WORKFLOW_ID "${BITBUCKET_BUILD_NUMBER}"
            add_var WORKFLOW_NAME "${BITBUCKET_BUILD_NUMBER}"
            add_var COMMIT_HASH "${BITBUCKET_COMMIT:-unknown}"

        elif [[ -n "${BUILD_NUMBER:-}" ]]; then
            add_var CI "Bamboo"
            add_var RUN_ID "${BUILD_NUMBER}"
            add_var REF_NAME "${BRANCH_NAME:-unknown}"
            add_var REPOSITORY "${BUILD_REPOSITORY_NAME:-unknown}"
            add_var WORKFLOW_ID "${BUILD_NUMBER}"
            add_var WORKFLOW_NAME "${BUILD_NAME:-$BUILD_NUMBER}"
            add_var COMMIT_HASH "${BUILD_VCS_NUMBER:-unknown}"

        elif [[ -n "${CIRCLE_WORKFLOW_ID:-}" ]]; then
            add_var CI "CircleCI"
            add_var RUN_ID "${CIRCLE_WORKFLOW_ID}"
            add_var REF_NAME "${CIRCLE_BRANCH:-unknown}"
            add_var REPOSITORY "${CIRCLE_PROJECT_REPONAME:-unknown}"
            add_var WORKFLOW_ID "${CIRCLE_WORKFLOW_ID}"
            add_var WORKFLOW_NAME "${CIRCLE_WORKFLOW_ID}"
            add_var COMMIT_HASH "${CIRCLE_SHA1:-unknown}"

        elif [[ -n "${BUILD_BUILDID:-}" ]]; then
            add_var CI "AzureDevOps"
            add_var RUN_ID "${BUILD_BUILDID}"
            add_var REF_NAME "${BUILD_SOURCEBRANCHNAME:-unknown}"
            add_var REPOSITORY "${BUILD_REPOSITORY_URI:-unknown}"
            add_var WORKFLOW_ID "${BUILD_BUILDID}"
            add_var WORKFLOW_NAME "${BUILD_DEFINITIONNAME:-$BUILD_BUILDID}"
            add_var COMMIT_HASH "${BUILD_SOURCEVERSION:-unknown}"
        fi

        log "CI variables saved using vars.sh"
    fi
fi

# --------------------------------------------------
# INI parser
# --------------------------------------------------

read_config_value() {
    local section="$1"
    local key="$2"

    awk -v wanted_section="$section" -v wanted_key="$key" '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }

        /^[[:space:]]*[;#]/ {
            next
        }

        /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
            current_section = $0
            sub(/^[[:space:]]*\[/, "", current_section)
            sub(/\][[:space:]]*$/, "", current_section)
            current_section = trim(current_section)
            next
        }

        {
            if (current_section != wanted_section) {
                next
            }

            pos = index($0, "=")
            if (!pos) {
                next
            }

            current_key = trim(substr($0, 1, pos - 1))
            if (current_key != wanted_key) {
                next
            }

            value = trim(substr($0, pos + 1))

            if (value ~ /^".*"$/ || value ~ /^'\''.*'\''$/) {
                value = substr(value, 2, length(value) - 2)
            }

            print value
            exit
        }
    ' "$CONFIG_FILE"
}

# --------------------------------------------------
# Read configuration
# --------------------------------------------------

TOOL_NAME="$(read_config_value "tool" "name")"
SAMPLING_INTERVAL="$(read_config_value "tool.configuration" "sampling_interval")"
EVENTS="$(read_config_value "tool.configuration" "events")"
HAS_BASELINE="$(read_config_value "methodology.execution" "baseline")"

[[ -n "$TOOL_NAME" ]] || die "Missing tool.name in config"
[[ -n "$SAMPLING_INTERVAL" ]] || die "Missing sampling_interval in config"
[[ -n "$EVENTS" ]] || die "Missing events in config"

TOOL_SCRIPT="$SCRIPT_DIR/${TOOL_NAME}.sh"
[[ -f "$TOOL_SCRIPT" ]] || die "Tool script not found: $TOOL_SCRIPT"

log "Tool: $TOOL_NAME"
log "Sampling interval: $SAMPLING_INTERVAL"
log "Events: $EVENTS"
log "Baseline enabled: ${HAS_BASELINE:-false}"

# --------------------------------------------------
# Process helpers
# --------------------------------------------------

is_running() {
    local pid_file="$1"
    local pid

    [[ -f "$pid_file" ]] || return 1

    pid="$(<"$pid_file")"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1

    kill -0 "$pid" 2>/dev/null
}

start_process() {
    local output_file="$1"
    local pid_file="$2"
    local timer_start="$3"
    shift 3

    if is_running "$pid_file"; then
        die "Process already running: PID $(<"$pid_file")"
    fi

    rm -f -- "$pid_file"
    mkdir -p "$(dirname "$output_file")"

    : > "$output_file"
    date +%s > "$timer_start"

    nohup bash "$TOOL_SCRIPT" "$output_file" "$@" \
        >> "$TOOL_LOG_FILE" 2>&1 &

    local pid=$!
    printf '%s\n' "$pid" > "$pid_file"

    sleep 1

    if ! kill -0 "$pid" 2>/dev/null; then
        rm -f -- "$pid_file"
        die "Process failed to start. Check $TOOL_LOG_FILE"
    fi

    log "Started PID $pid"
    log "Output: $output_file"
}

# Stop directly with SIGTERM, then wait up to 5 seconds.
stop_process() {
    local pid_file="$1"
    local timer_end="$2"
    local pid
    local attempts=0

    if [[ ! -f "$pid_file" ]]; then
        log "No PID file: $pid_file"
        return 0
    fi

    pid="$(<"$pid_file")"

    if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
        rm -f -- "$pid_file"
        die "Invalid PID in $pid_file"
    fi

    if ! kill -0 "$pid" 2>/dev/null; then
        rm -f -- "$pid_file"
        log "Process $pid is no longer running"
        date +%s > "$timer_end"
        return 0
    fi

    log "Sending SIGTERM to PID $pid"
    kill -TERM "$pid" 2>/dev/null || true

    while kill -0 "$pid" 2>/dev/null && (( attempts < 5 )); do
        sleep 1
        ((attempts += 1))
    done

    if kill -0 "$pid" 2>/dev/null; then
        log "ERROR: PID $pid is still running after SIGTERM"
        log "Keeping PID file for later inspection"
        return 1
    fi

    rm -f -- "$pid_file"
    date +%s > "$timer_end"

    log "Process $pid stopped"
}

# --------------------------------------------------
# Baseline
# --------------------------------------------------

baseline_has_data() {
    [[ -s "$PERF_BASELINE_FILE" ]]
}

start_baseline() {
    start_process \
        "$PERF_BASELINE_FILE" \
        "$BASELINE_PID_FILE" \
        "$TIMER_FILE_BASELINE_START" \
        --sampling_interval "$SAMPLING_INTERVAL" \
        --events "$EVENTS"
}

stop_baseline() {
    stop_process "$BASELINE_PID_FILE" "$TIMER_FILE_BASELINE_END"
}

start_normal_measurement() {
    start_process \
        "$PERF_OUTPUT_FILE" \
        "$PID_FILE" \
        "$TIMER_FILE_START" \
        --sampling_interval "$SAMPLING_INTERVAL" \
        --events "$EVENTS"
}

run_baseline_automatically() {
    log "Baseline file is empty; running baseline for 10 seconds."

    start_baseline
    sleep 10
    stop_baseline

    if is_running "$BASELINE_PID_FILE"; then
        die "Baseline process is still running; normal measurement will not start."
    fi

    if ! baseline_has_data; then
        die "Baseline produced no data. Inspect $TOOL_LOG_FILE"
    fi

    log "Baseline completed; starting normal measurement."
    start_normal_measurement
}

# --------------------------------------------------
# Actions
# --------------------------------------------------

case "$ACTION" in
    start_measurement)
        if [[ "${HAS_BASELINE,,}" == "true" ]] &&
           ! baseline_has_data; then
            run_baseline_automatically
        else
            start_normal_measurement
        fi
        ;;

    stop_measurement)
        stop_process "$PID_FILE" "$TIMER_FILE_END"
        ;;

    baseline_measurement)
        run_baseline_automatically
        ;;

    stop_baseline_measurement)
        stop_baseline
        ;;

    *)
        usage
        ;;
esac
