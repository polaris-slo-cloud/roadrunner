#!/bin/bash
# Usage:
#   sudo ./fanout-wasmedge.sh [NUM_TASKS]
#   # or via envs:
#   sudo NUM_TASKS=100 STORAGE_IP=127.0.0.1:8888 FUNCB_URL=http://127.0.0.1:8080/ ./fanout-wasmedge.sh
#
# Notes:
#   - Requires containerd (ctr) and the WasmEdge runtime shim.
#   - We keep going even if a run fails; the exit code is recorded in the CSV.

set -u
set -o pipefail

# ----- root check -----
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

# ---------- Config ----------
NAMESPACE="k8s.io"
RUNTIME="io.containerd.wasmedge.v1"

# Server container (func_b)
SERVER_IMAGE="docker.io/keniack/func_b_vanilla:latest"
SERVER_BIN="/func_b_vanilla.wasm"

# Client container (fanout)
CLIENT_IMAGE="docker.io/keniack/wasm-fanout:latest"
CLIENT_BIN="/wasm-fanout.wasm"

# Inputs
FILES=("file_10M.txt")
# FILES=("file_1M.txt" "file_2M.txt" "file_4M.txt" "file_6M.txt" "file_8M.txt" "file_10M.txt" "file_20M.txt" "file_40M.txt" "file_60M.txt" "file_100M.txt" "file_200M.txt" "file_300M.txt" "file_400M.txt" "file_500M.txt")


# NUM_TASKS: positional arg > env > default
NUM_TASKS="${1:-${NUM_TASKS:-100}}"

# Networking envs (can be overridden via env)
STORAGE_IP="${STORAGE_IP:-127.0.0.1:8888}"
FUNCB_URL="${FUNCB_URL:-http://127.0.0.1:8080/}"

# Output locations
RESULT_DIR="./output/parallel_wasmedge"
LOG_DIR="$RESULT_DIR/logs"
CSV="$RESULT_DIR/results.csv"

mkdir -p "$LOG_DIR"

# CSV header
if [ ! -f "$CSV" ]; then
  echo "file,num_tasks,start_iso,end_iso,elapsed_seconds,client_exit_code,server_name,client_name,server_log,client_log" > "$CSV"
fi

cleanup_round() {
  # Best-effort cleanup of leftover tasks/containers between rounds
  sudo ctr -n "$NAMESPACE" containers list -q | xargs -r sudo ctr -n "$NAMESPACE" task kill --signal SIGKILL >/dev/null 2>&1 || true
  sudo ctr -n "$NAMESPACE" containers list -q | xargs -r sudo ctr -n "$NAMESPACE" containers rm >/dev/null 2>&1 || true
}

for file in "${FILES[@]}"; do
  echo "=== ROUND: file=$file, NUM_TASKS=$NUM_TASKS ==="

  # Safe names for container + logs
  safe_file="${file//_/-}"
  safe_file="${safe_file%.txt}"
  ts="$(date +%Y%m%d-%H%M%S)"

  server_name="wb1-${NUM_TASKS}-${safe_file}"
  client_name="wb2-${NUM_TASKS}-${safe_file}"

  server_log="$LOG_DIR/${ts}-${safe_file}-server.log"
  client_log="$LOG_DIR/${ts}-${safe_file}-client.log"

  start_ns="$(date +%s%N)"
  start_iso="$(date -Iseconds)"

  # ---- Start server (background) ----
  # Args: /func_b_vanilla.wasm aaaa "$file"
  sudo ctr -n "$NAMESPACE" run --rm \
    --runtime="$RUNTIME" \
    --net-host=true \
    --env STORAGE_IP="$STORAGE_IP" \
    "$SERVER_IMAGE" "$server_name" \
    "$SERVER_BIN" aaaa "$file" >"$server_log" 2>&1 &
  server_pid=$!

  # Give the server a moment to start
  sleep 1

  # ---- Run client (foreground) ----
  # Env: FUNCB_URL + STORAGE_IP + NUM_TASKS
  if sudo ctr -n "$NAMESPACE" run --rm \
      --runtime="$RUNTIME" \
      --net-host=true \
      --env FUNCB_URL="$FUNCB_URL" \
      --env STORAGE_IP="$STORAGE_IP" \
      --env NUM_TASKS="$NUM_TASKS" \
      "$CLIENT_IMAGE" "$client_name" \
      "$CLIENT_BIN" >"$client_log" 2>&1; then
    rc=0
  else
    rc=$?
  fi

  # ---- Stop server and cleanup ----
  # Try via ctr, then fall back to host PID
  sudo ctr -n "$NAMESPACE" task kill --signal SIGKILL "$server_name" >/dev/null 2>&1 || true
  sudo kill -9 "$server_pid" >/dev/null 2>&1 || true

  sleep 1
  cleanup_round

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
