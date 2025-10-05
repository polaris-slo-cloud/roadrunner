#!/bin/bash
# Usage:
#   sudo ./fanout-container.sh [NUM_TASKS]
#   # or set envs:
#   sudo NUM_TASKS=100 STORAGE_IP=127.0.0.1:8888 FUNCB_URL=http://localhost:8080/ ./fanout-container.sh
#
# Notes:
#   - Requires containerd (ctr). This script uses the default namespace k8s.io.
#   - We keep going even if a run fails; exit code is recorded in CSV.

set -u
set -o pipefail

# ----- root check (same as your original) -----
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

# ---------- Config ----------
NAMESPACE="k8s.io"

# Server container (serves files to client)
SERVER_IMAGE="docker.io/username/web-server:latest"
SERVER_BIN="/function"

# Client container (your blocking fanout binary)
CLIENT_IMAGE="docker.io/username/fanout-native:blocking"

# Inputs
FILES=("file_10M.txt")
# FILES=("file_1M.txt" "file_2M.txt" "file_4M.txt" "file_6M.txt" "file_8M.txt" "file_10M.txt" "file_20M.txt" "file_40M.txt" "file_60M.txt" "file_100M.txt" "file_200M.txt" "file_300M.txt" "file_400M.txt" "file_500M.txt")


# NUM_TASKS: positional arg > env > default
NUM_TASKS="${1:-${NUM_TASKS:-1}}"

# Networking envs (can be overridden via env)
STORAGE_IP="${STORAGE_IP:-127.0.0.1:8888}"
FUNCB_URL="${FUNCB_URL:-http://localhost:8080/}"

# Output locations
RESULT_DIR="./output/fanout_container"
LOG_DIR="$RESULT_DIR/logs"
CSV="$RESULT_DIR/results.csv"

mkdir -p "$LOG_DIR"

# CSV header
if [ ! -f "$CSV" ]; then
  echo "file,num_tasks,start_iso,end_iso,elapsed_seconds,client_exit_code,server_name,client_name,server_log,client_log" > "$CSV"
fi

cleanup() {
  # Best-effort cleanup of any leftover tasks/containers from prior failures
  sudo ctr -n "$NAMESPACE" containers list -q | xargs -r sudo ctr -n "$NAMESPACE" task kill --signal SIGKILL >/dev/null 2>&1 || true
  sudo ctr -n "$NAMESPACE" containers list -q | xargs -r sudo ctr -n "$NAMESPACE" containers rm >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

for file in "${FILES[@]}"; do
  echo "=== ROUND: file=$file, NUM_TASKS=$NUM_TASKS ==="

  # Safe names for container + logs
  safe_file="${file//_/-}"
  safe_file="${safe_file%.txt}"
  ts="$(date +%Y%m%d-%H%M%S)"

  server_name="nat-${NUM_TASKS}-${safe_file}"
  client_name="2nat-${NUM_TASKS}-${safe_file}"

  server_log="$LOG_DIR/${ts}-${safe_file}-server.log"
  client_log="$LOG_DIR/${ts}-${safe_file}-client.log"

  start_ns="$(date +%s%N)"
  start_iso="$(date -Iseconds)"

  # ---- Start server (background) ----
  # Args: /function arg "$file"
  sudo ctr -n "$NAMESPACE" run --rm \
    --net-host=true \
    --env STORAGE_IP="$STORAGE_IP" \
    "$SERVER_IMAGE" "$server_name" \
    "$SERVER_BIN" arg "$file" >"$server_log" 2>&1 &
  server_pid=$!

  # Give server a moment to start
  sleep 1

  # ---- Run client (foreground) ----
  # Pass FUNCB_URL + NUM_TASKS
  if sudo ctr -n "$NAMESPACE" run --rm \
      --net-host=true \
      --env FUNCB_URL="$FUNCB_URL" \
      --env NUM_TASKS="$NUM_TASKS" \
      "$CLIENT_IMAGE" "$client_name" \
      >"$client_log" 2>&1; then
    rc=0
  else
    rc=$?
  fi

  # ---- Stop server and cleanup ----
  # Try graceful task kill via ctr, then fall back to host PID
  sudo ctr -n "$NAMESPACE" task kill --signal SIGKILL "$server_name" >/dev/null 2>&1 || true
  sudo kill -9 "$server_pid" >/dev/null 2>&1 || true

  # Small pause + best-effort global cleanup between rounds
  sleep 1
  cleanup

  end_ns="$(date +%s%N)"
  end_iso="$(date -Iseconds)"
  elapsed="$(awk -v s="$start_ns" -v e="$end_ns" 'BEGIN { printf "%.6f", (e-s)/1000000000 }')"

  # ---- Record CSV ----
  echo "\"$file\",\"$NUM_TASKS\",\"$start_iso\",\"$end_iso\",\"$elapsed\",\"$rc\",\"$server_name\",\"$client_name\",\"$server_log\",\"$client_log\"" >> "$CSV"

  echo "Logs -> server: $server_log"
  echo "        client: $client_log"
  echo
done

echo "All files have been processed."
echo "CSV summary -> $CSV"
