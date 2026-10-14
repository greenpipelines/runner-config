
#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# ARGUMENT PARSING
# =========================================================

if [[ $# -lt 1 ]]; then
    echo "[ERROR] Missing output file argument."
    echo "[INFO] Usage:"
    echo "  $0 <output_file> --sampling_interval <ms> --events <event1,event2,...>"
    exit 1
fi

OUTPUT_FILE="$1"
shift

INTERVAL_MS=1000
REQUESTED_EVENTS=()

function show_usage() {
    echo "[INFO] Usage:"
    echo "  $0 <output_file> --sampling_interval <ms> --events <event1,event2,...>"
    exit 1
}

function parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --sampling_interval)
                if [[ $# -lt 2 ]]; then
                    echo "[ERROR] Missing value for --sampling_interval."
                    show_usage
                fi

                INTERVAL_MS="$2"
                shift 2
                ;;

            --events)
                if [[ $# -lt 2 ]]; then
                    echo "[ERROR] Missing value for --events."
                    show_usage
                fi

                IFS=',' read -r -a REQUESTED_EVENTS <<< "$2"
                shift 2
                ;;

            *)
                echo "[ERROR] Unknown argument: $1"
                show_usage
                ;;
        esac
    done

    if [[ ! "$INTERVAL_MS" =~ ^[0-9]+$ ]] || (( INTERVAL_MS <= 0 )); then
        echo "[ERROR] Sampling interval must be a positive integer."
        exit 1
    fi

    if (( ${#REQUESTED_EVENTS[@]} == 0 )); then
        echo "[ERROR] No events specified."
        show_usage
    fi
}

# =========================================================
# OUTPUT DIRECTORY
# =========================================================

function setup_output_dir() {
    local output_dir
    output_dir="$(dirname "$OUTPUT_FILE")"

    mkdir -p "$output_dir"

    echo "[DEBUG] Output directory: $output_dir"
    echo "[INFO] Output file: $OUTPUT_FILE"
}

# =========================================================
# PERF PERMISSIONS
# =========================================================

function check_perf_paranoid() {
    local perf_paranoid

    if [[ ! -r /proc/sys/kernel/perf_event_paranoid ]]; then
        echo "[WARNING] Cannot read perf_event_paranoid."
        return
    fi

    perf_paranoid=$(< /proc/sys/kernel/perf_event_paranoid)

    if [[ "$perf_paranoid" =~ ^-?[0-9]+$ ]] && (( perf_paranoid > 1 )); then
        echo "[WARNING] perf_event_paranoid is $perf_paranoid."
        echo "[WARNING] Elevated privileges may be required."
    else
        echo "[DEBUG] perf_event_paranoid is $perf_paranoid"
    fi
}

# =========================================================
# EVENT VALIDATION
# =========================================================

function validate_events() {
    local available_events=()
    local valid_events=()
    local invalid_events=()
    local event

    if ! command -v perf >/dev/null 2>&1; then
        echo "[ERROR] perf is not installed or not available in PATH."
        exit 1
    fi

    mapfile -t available_events < <(
        perf list 2>/dev/null |
            grep -E '^ *power/energy-[^ ]+/' |
            awk '{print $1}' ||
            true
    )

    for event in "${REQUESTED_EVENTS[@]}"; do
        # Trim surrounding whitespace.
        event="${event#"${event%%[![:space:]]*}"}"
        event="${event%"${event##*[![:space:]]}"}"

        [[ -z "$event" ]] && continue

        if printf '%s\n' "${available_events[@]}" | grep -Fxq "$event"; then
            valid_events+=("$event")
        else
            invalid_events+=("$event")
        fi
    done

    if (( ${#invalid_events[@]} > 0 )); then
        echo "[WARNING] Unavailable events: ${invalid_events[*]}"
    fi

    if (( ${#valid_events[@]} == 0 )); then
        echo "[ERROR] No valid requested events are available."
        echo "[INFO] Available power events:"
        printf '  %s\n' "${available_events[@]}"
        exit 1
    fi

    REQUESTED_EVENTS=("${valid_events[@]}")

    echo "[INFO] Valid events: ${REQUESTED_EVENTS[*]}"
}

# =========================================================
# RUN PERF
# =========================================================

function run_perf() {
    local events_csv
    events_csv=$(IFS=,; echo "${REQUESTED_EVENTS[*]}")

    echo "[INFO] Starting perf measurement..."
    echo "[INFO] Sampling interval: ${INTERVAL_MS} ms"
    echo "[INFO] Events: ${events_csv}"
    echo "[INFO] Output: ${OUTPUT_FILE}"

    echo "[DEBUG] Command:"
    echo "perf stat -a -I $INTERVAL_MS -e $events_csv"

    # Keep perf's output in the specified file.
    # perf stat writes measurement results to stderr.
    LC_NUMERIC=C perf stat \
        -a \
        -I "$INTERVAL_MS" \
        -e "$events_csv" \
        2> "$OUTPUT_FILE"

    echo "[INFO] Perf measurement completed."
    echo "[INFO] Output saved to: $OUTPUT_FILE"
}

# =========================================================
# MAIN
# =========================================================

parse_arguments "$@"
setup_output_dir
check_perf_paranoid
validate_events
run_perf
