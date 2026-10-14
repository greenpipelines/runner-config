#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

OUTPUT_DIR="/tmp/wattsci"
BASELINE_DIR="$OUTPUT_DIR/baseline"

VARS_SCRIPT="$SCRIPT_DIR/vars.sh"
CI_VARS_SCRIPT="$SCRIPT_DIR/ci_vars.sh"

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
# Helpers
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
# CI variables: reuse existing scripts
# --------------------------------------------------

if [[ -f "$CI_VARS_SCRIPT" ]]; then
    # ci_vars.sh sources vars.sh and defines load_ci_vars.
    source "$CI_VARS_SCRIPT"

    if declare -F initialize_vars >/dev/null &&
       declare -F load_ci_vars >/dev/null; then
        initialize_vars
        load_ci_vars
        log "CI variables saved to /tmp/wattsci/vars.sh"
    else
        die "ci_vars.sh must define initialize_vars and load_ci_vars"
    fi
elif [[ -f "$VARS_SCRIPT" ]]; then
    log "WARNING: ci_vars.sh not found; skipping CI variable collection"
else
    log "WARNING: vars.sh and ci_vars.sh not found; skipping CI variables"
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

        /^[[:space:]]*[;#]/ { next }

        /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
            current_section = $0
            sub(/^[[:space:]]*\[/, "", current_section)
            sub(/\][[:space:]]*$/, "", current_section)
            current_section = trim(current_section)
            next
        }

        {
            if (current_section != wanted_section) next

            pos = index($0, "=")
            if (!pos) next

            current_key = trim(substr($0, 1, pos - 1))
            if (current_key != wanted_key) next

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
# Configuration
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
log "Baseline enabled: ${HAS_BASELINE:-false}"

# --------------------------------------------------
# Process management
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
        die "Invalid PID in $pid_file"
    fi

    if ! kill -0 "$pid" 2>/dev/null; then
        rm -f -- "$pid_file"
        date +%s > "$timer_end"
        log "Process $pid is no longer running"
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
        return 1
    fi

    rm -f -- "$pid_file"
    date +%s > "$timer_end"
    log "Process $pid stopped"
}

# --------------------------------------------------
# Measurement actions
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
    log "Running baseline for 10 seconds"

    start_baseline
    sleep 10
    stop_baseline

    if is_running "$BASELINE_PID_FILE"; then
        die "Baseline is still running; normal measurement will not start"
    fi

    if ! baseline_has_data; then
        die "Baseline produced no data. Check $TOOL_LOG_FILE"
    fi

    log "Baseline completed; starting normal measurement"
    start_normal_measurement
}

# --------------------------------------------------
# Dispatch
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
