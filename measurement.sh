#!/usr/bin/env bash

set -euo pipefail

# ============================================================
# General paths
# ============================================================

OUTPUT_DIR="/tmp/wattsci"

PID_FILE="$OUTPUT_DIR/measurement.pid"

# Main measurement timers
TIMER_FILE_START="$OUTPUT_DIR/timer_start.txt"
TIMER_FILE_END="$OUTPUT_DIR/timer_end.txt"

# Baseline measurement timers
TIMER_FILE_BASELINE_START="$OUTPUT_DIR/baseline/start.txt"
TIMER_FILE_BASELINE_END="$OUTPUT_DIR/baseline/end.txt"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$OUTPUT_DIR" "$OUTPUT_DIR/baseline"

# ============================================================
# Arguments
# ============================================================

CONFIG_FILE=""
ACTION=""

usage() {
    echo "Usage: $0 --config <config_file> --action <action>"
    echo
    echo "Actions:"
    echo "  start_measurement"
    echo "  stop_measurement"
    echo "  baseline_measurement"
    echo "  stop_baseline_measurement"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            if [[ $# -lt 2 ]]; then
                echo "Error: --config requires a file path." >&2
                exit 1
            fi
            CONFIG_FILE="$2"
            shift 2
            ;;
        --action)
            if [[ $# -lt 2 ]]; then
                echo "Error: --action requires a value." >&2
                exit 1
            fi
            ACTION="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: unknown argument '$1'." >&2
            usage
            exit 1
            ;;
    esac
done

if [[ -z "$CONFIG_FILE" || -z "$ACTION" ]]; then
    usage
    exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: configuration file not found: $CONFIG_FILE" >&2
    exit 1
fi

# ============================================================
# Save configuration copy
# ============================================================

CONFIG_OUTPUT_FILE="$OUTPUT_DIR/benchmark_measurement.conf"

cp -- "$CONFIG_FILE" "$CONFIG_OUTPUT_FILE"

echo "Configuration copied to: $CONFIG_OUTPUT_FILE"

# ============================================================
# Read INI configuration
# Supports quoted and unquoted values.
# Examples:
#   name = "perf"          -> perf
#   sampling_interval = 20 -> 20
#   baseline = true        -> true
# ============================================================

read_config_value() {
    local section="$1"
    local key="$2"

    awk -v section="$section" -v key="$key" '
        /^[[:space:]]*\[/ {
            current_section = $0
            sub(/^[[:space:]]*\[/, "", current_section)
            sub(/\][[:space:]]*$/, "", current_section)
            next
        }

        current_section == section {
            line = $0

            if (line ~ /^[[:space:]]*$/ ||
                line ~ /^[[:space:]]*[#;]/) {
                next
            }

            separator = index(line, "=")

            if (separator > 0) {
                k = substr(line, 1, separator - 1)
                v = substr(line, separator + 1)

                gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)

                if (k == key) {
                    # Remove quotes only if they surround the whole value.
                    if (length(v) >= 2) {
                        first = substr(v, 1, 1)
                        last = substr(v, length(v), 1)

                        if ((first == "\"" && last == "\"") ||
                            (first == "\047" && last == "\047")) {
                            v = substr(v, 2, length(v) - 2)
                        }
                    }

                    print v
                    exit
                }
            }
        }
    ' "$CONFIG_FILE"
}

TOOL_NAME="$(read_config_value "tool" "name")"
SAMPLING_INTERVAL="$(read_config_value "tool.configuration" "sampling_interval")"
EVENTS="$(read_config_value "tool.configuration" "events")"

if [[ -z "$TOOL_NAME" ]]; then
    echo "Error: tool.name is missing from the configuration." >&2
    exit 1
fi

echo "Selected tool: $TOOL_NAME"

# ============================================================
# Tool-specific configuration
# ============================================================

TOOL_ARGS=()
TOOL_LOG_FILE=""

case "$TOOL_NAME" in
    perf)
        # Define perf output files only when perf is selected.
        PERF_OUTPUT_FILE="$OUTPUT_DIR/data.txt"
        PERF_BASELINE_FILE="$OUTPUT_DIR/baseline/data.txt"

        TOOL_LOG_FILE="$OUTPUT_DIR/perf.log"

        if [[ -z "$SAMPLING_INTERVAL" || -z "$EVENTS" ]]; then
            echo "Error: perf requires sampling_interval and events." >&2
            exit 1
        fi

        TOOL_ARGS=(
            --sampling_interval "$SAMPLING_INTERVAL"
            --events "$EVENTS"
        )
        ;;

    *)
        echo "Error: unsupported tool '$TOOL_NAME'." >&2
        exit 1
        ;;
esac

# ============================================================
# Start measurement
# ============================================================

start_measurement() {
    local output_file="$1"
    shift

    local tool_script="$SCRIPT_DIR/${TOOL_NAME}.sh"

    if [[ ! -f "$tool_script" ]]; then
        echo "Error: tool script not found: $tool_script" >&2
        return 1
    fi

    if [[ -f "$PID_FILE" ]]; then
        local old_pid
        old_pid="$(cat "$PID_FILE")"

        if [[ "$old_pid" =~ ^[0-9]+$ ]] &&
           kill -0 "$old_pid" 2>/dev/null; then
            echo "Error: measurement already running (PID: $old_pid)." >&2
            return 1
        fi

        rm -f "$PID_FILE"
    fi

    mkdir -p "$(dirname -- "$output_file")"

    nohup bash "$tool_script" \
        "$output_file" \
        "$@" \
        > "$TOOL_LOG_FILE" 2>&1 &

    local pid=$!
    printf '%s\n' "$pid" > "$PID_FILE"

    sleep 1

    if ! kill -0 "$pid" 2>/dev/null; then
        echo "Error: measurement process exited during startup." >&2
        rm -f "$PID_FILE"
        cat "$TOOL_LOG_FILE" >&2 || true
        return 1
    fi

    echo "Started $TOOL_NAME measurement."
    echo "PID: $pid"
    echo "Output: $output_file"
}

# ============================================================
# Stop measurement
# ============================================================

stop_measurement() {
    if [[ ! -f "$PID_FILE" ]]; then
        echo "No measurement PID file found."
        return 0
    fi

    local pid
    pid="$(cat "$PID_FILE")"

    if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
        echo "Error: invalid PID in $PID_FILE." >&2
        rm -f "$PID_FILE"
        return 1
    fi

    if kill -0 "$pid" 2>/dev/null; then
        kill -INT "$pid" 2>/dev/null || true

        for _ in {1..15}; do
            if ! kill -0 "$pid" 2>/dev/null; then
                break
            fi
            sleep 1
        done

        if kill -0 "$pid" 2>/dev/null; then
            echo "Warning: process is still running; sending TERM." >&2
            kill -TERM "$pid" 2>/dev/null || true
        fi
    fi

    rm -f "$PID_FILE"
    echo "Measurement stopped."
}

# ============================================================
# Main measurement
# ============================================================

main_measurement() {
    date +%s.%N > "$TIMER_FILE_START"

    start_measurement "$PERF_OUTPUT_FILE" "${TOOL_ARGS[@]}"
}

stop_main_measurement() {
    stop_measurement
    date +%s.%N > "$TIMER_FILE_END"
}

# ============================================================
# Baseline measurement
# ============================================================

baseline_measurement() {
    mkdir -p "$OUTPUT_DIR/baseline"

    date +%s.%N > "$TIMER_FILE_BASELINE_START"

    start_measurement "$PERF_BASELINE_FILE" "${TOOL_ARGS[@]}"
}

stop_baseline_measurement() {
    stop_measurement
    date +%s.%N > "$TIMER_FILE_BASELINE_END"
}

# ============================================================
# Action dispatcher
# ============================================================

case "$ACTION" in
    start_measurement)
        main_measurement
        ;;
    stop_measurement)
        stop_main_measurement
        ;;
    baseline_measurement)
        baseline_measurement
        ;;
    stop_baseline_measurement)
        stop_baseline_measurement
        ;;
    *)
        echo "Error: unknown action '$ACTION'." >&2
        usage
        exit 1
        ;;
esac
