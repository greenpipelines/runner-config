#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

OUTPUT_DIR="/tmp/wattsci"
BASELINE_DIR="$OUTPUT_DIR/baseline"

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
# Load existing vars.sh without changing its path
# --------------------------------------------------

if [[ -f "$VARS_FILE" ]]; then
    source "$VARS_FILE"
fi

# --------------------------------------------------
# Logging and usage
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
    echo "Actions:"
    echo "  start_measurement"
    echo "  stop_measurement"
    echo "  baseline_measurement"
    echo "  stop_baseline_measurement"
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

[[ -n "$CONFIG_FILE" ]] || usage
[[ -n "$ACTION" ]] || usage
[[ -f "$CONFIG_FILE" ]] || die "Config file not found: $CONFIG_FILE"

# --------------------------------------------------
# Directories and config copy
# --------------------------------------------------

mkdir -p "$OUTPUT_DIR" "$BASELINE_DIR"

CONFIG_FILE="$(realpath -- "$CONFIG_FILE")"
CONFIG_FILENAME="$(basename -- "$CONFIG_FILE")"
CONFIG_OUTPUT_FILE="$OUTPUT_DIR/$CONFIG_FILENAME"

cp -- "$CONFIG_FILE" "$CONFIG_OUTPUT_FILE"

# --------------------------------------------------
# INI configuration parser
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
# Read tool configuration
# --------------------------------------------------

TOOL_NAME="$(read_config_value "tool" "name")"
SAMPLING_INTERVAL="$(read_config_value "tool.configuration" "sampling_interval")"
EVENTS="$(read_config_value "tool.configuration" "events")"
HAS_BASELINE="$(read_config_value "tool.configuration" "hasbaseline")"

[[ -n "$TOOL_NAME" ]] || die "Missing [tool] name in config"
[[ -n "$SAMPLING_INTERVAL" ]] || die "Missing sampling_interval in config"
[[ -n "$EVENTS" ]] || die "Missing events in config"

TOOL_SCRIPT="$SCRIPT_DIR/${TOOL_NAME}.sh"

[[ -f "$TOOL_SCRIPT" ]] || die "Tool script not found: $TOOL_SCRIPT"

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

start_measurement_process() {
    local output_file="$1"
    local pid_file="$2"
    local start_file="$3"
    shift 3

    if is_running "$pid_file"; then
        die "Measurement already running (PID $(<"$pid_file"))"
    fi

    rm -f -- "$pid_file"

    mkdir -p "$(dirname "$output_file")"

    : > "$output_file"
    date +%s > "$start_file"

    nohup bash "$TOOL_SCRIPT" "$output_file" "$@" \
        >> "$TOOL_LOG_FILE" 2>&1 &

    local pid=$!

    printf '%s\n' "$pid" > "$pid_file"

    sleep 1

    if ! kill -0 "$pid" 2>/dev/null; then
        rm -f -- "$pid_file"
        die "Measurement failed to start. Check $TOOL_LOG_FILE"
    fi

    log "Measurement started (PID $pid)"
    log "Output: $output_file"
}

stop_measurement_process() {
    local pid_file="$1"
    local end_file="$2"
    local pid
    local attempts=0

    if [[ ! -f "$pid_file" ]]; then
        log "No PID file found: $pid_file"
        return 0
    fi

    pid="$(<"$pid_file")"

    if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
        rm -f -- "$pid_file"
        die "Invalid PID in $pid_file"
    fi

    if ! kill -0 "$pid" 2>/dev/null; then
        rm -f -- "$pid_file"
        log "Process $pid is not running"
        return 0
    fi

    log "Stopping measurement (PID $pid)"

    kill -INT "$pid" 2>/dev/null || true

    while kill -0 "$pid" 2>/dev/null && (( attempts < 15 )); do
        sleep 1
        ((attempts += 1))
    done

    if kill -0 "$pid" 2>/dev/null; then
        log "Process did not stop with SIGINT; sending SIGTERM"
        kill -TERM "$pid" 2>/dev/null || true
    fi

    attempts=0

    while kill -0 "$pid" 2>/dev/null && (( attempts < 5 )); do
        sleep 1
        ((attempts += 1))
    done

    if kill -0 "$pid" 2>/dev/null; then
        log "WARNING: process $pid is still running"
    else
        rm -f -- "$pid_file"
    fi

    date +%s > "$end_file"

    log "Measurement stopped"
}

# --------------------------------------------------
# Baseline helpers
# --------------------------------------------------

baseline_has_data() {
    [[ -s "$PERF_BASELINE_FILE" ]]
}

start_baseline() {
    if is_running "$BASELINE_PID_FILE"; then
        log "Baseline measurement is already running"
        return 0
    fi

    start_measurement_process \
        "$PERF_BASELINE_FILE" \
        "$BASELINE_PID_FILE" \
        "$TIMER_FILE_BASELINE_START" \
        --sampling_interval "$SAMPLING_INTERVAL" \
        --events "$EVENTS"
}

stop_baseline() {
    stop_measurement_process \
        "$BASELINE_PID_FILE" \
        "$TIMER_FILE_BASELINE_END"
}

start_normal_measurement() {
    start_measurement_process \
        "$PERF_OUTPUT_FILE" \
        "$PID_FILE" \
        "$TIMER_FILE_START" \
        --sampling_interval "$SAMPLING_INTERVAL" \
        --events "$EVENTS"
}

run_baseline_automatically() {
    log "Baseline is enabled and its output is empty."
    log "Starting baseline measurement for 10 seconds."

    start_baseline

    sleep 10

    stop_baseline

    if ! baseline_has_data; then
        die "Baseline completed but no data was generated. Check $TOOL_LOG_FILE"
    fi

    log "Baseline completed."
    log "Starting normal measurement."

    start_normal_measurement
}

# --------------------------------------------------
# Actions
# --------------------------------------------------

case "$ACTION" in
    start_measurement)
        if [[ "${HAS_BASELINE,,}" == "true" ]] && ! baseline_has_data; then
            run_baseline_automatically
        else
            start_normal_measurement
        fi
        ;;

    stop_measurement)
        stop_measurement_process \
            "$PID_FILE" \
            "$TIMER_FILE_END"
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
