#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "[ERROR] Missing output file argument"
    echo "[INFO] Usage: $0 <output_file> events=<event1,event2,...> interval=<ms>"
    exit 1
fi

OUTPUT_FILE="$1"
shift 1

INTERVAL_MS=1000
REQUESTED_EVENTS=()

function show_usage() {
    echo "[INFO] Usage: $0 <output_file> events=<event1,event2,...> interval=<ms>"
    exit 1
}

function setup_output_dir() {
    mkdir -p "$(dirname "$OUTPUT_FILE")"
    echo "[DEBUG] Output directory created: $(dirname "$OUTPUT_FILE")"
}

function parse_arguments() {
    for arg in "$@"; do
        case "$arg" in
            interval=*)
                INTERVAL_MS="${arg#interval=}"
                echo "[INFO] Interval set to $INTERVAL_MS ms"
                ;;
            events=*)
                IFS=',' read -r -a REQUESTED_EVENTS <<< "${arg#events=}"
                echo "[INFO] Requested events: ${REQUESTED_EVENTS[*]}"
                ;;
            *)
                echo "[ERROR] Unknown argument: $arg"
                show_usage
                ;;
        esac
    done

    if [[ ${#REQUESTED_EVENTS[@]} -eq 0 ]]; then
        echo "[ERROR] No events specified."
        show_usage
    fi
}

function check_perf_paranoid() {
    local PERF_PARANOID
    PERF_PARANOID=$(< /proc/sys/kernel/perf_event_paranoid)
    if [[ "$PERF_PARANOID" -gt 1 ]]; then
        echo "[WARNING] perf_event_paranoid is $PERF_PARANOID. You may need root privileges."
    else
        echo "[DEBUG] perf_event_paranoid is $PERF_PARANOID"
    fi
}

function validate_events() {
    mapfile -t AVAILABLE_EVENTS < <(perf list | grep -E '^ *power/energy-[^ ]+/' | awk '{print $1}')
    VALID_EVENTS=()
    INVALID_EVENTS=()

    for evt in "${REQUESTED_EVENTS[@]}"; do
        if printf '%s\n' "${AVAILABLE_EVENTS[@]}" | grep -Fxq "$evt"; then
            VALID_EVENTS+=("$evt")
        else
            INVALID_EVENTS+=("$evt")
        fi
    done

    if (( ${#VALID_EVENTS[@]} == 0 )); then
        echo "[ERROR] No valid events available."
        exit 1
    fi

    if (( ${#INVALID_EVENTS[@]} > 0 )); then
        echo "[WARNING] Ignoring unavailable events: ${INVALID_EVENTS[*]}"
    fi

    echo "[INFO] Valid events to monitor: ${VALID_EVENTS[*]}"
}

function run_perf() {
    echo "[INFO] Starting perf measurement..."
    echo "[DEBUG] perf command: perf stat -a -I $INTERVAL_MS -e $(IFS=','; echo "${VALID_EVENTS[*]}")"
    LC_NUMERIC=C perf stat -a -I "$INTERVAL_MS" -e "$(IFS=','; echo "${VALID_EVENTS[*]}")" 2> "$OUTPUT_FILE"
    echo "[INFO] Perf measurement completed. Output saved to $OUTPUT_FILE"
}

setup_output_dir
parse_arguments "$@"
check_perf_paranoid
validate_events
run_perf