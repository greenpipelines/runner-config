#!/usr/bin/env bash
set -euo pipefail

var_file="/tmp/wattsci/vars.sh"

function add_var() {
    local key="$1"
    local value="$2"
    if grep -q "^${key}=" "$var_file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}='${value}'|" "$var_file"
    else
        echo "${key}='${value}'" >> "$var_file"
    fi
}

function read_vars() {
    if [ -f "$var_file" ]; then
        source "$var_file"
    fi
}

function initialize_vars() {
    mkdir -p "$(dirname "$var_file")"
    : > "$var_file"
}