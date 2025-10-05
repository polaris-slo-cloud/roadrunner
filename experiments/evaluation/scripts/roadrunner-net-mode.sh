#!/usr/bin/env bash
#
# Notes:
#   - Runs the fanout driver as a single container (no separate workers).
#   - Saves per-run logs and a CSV summary like the kernel-mode script.
#   - Continues on errors; non-zero exit codes are recorded in the CSV.

set -u
set -o pipefail

# ----- root check -----
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

# ---------- Config ----------
NAMESPACE="k8s.io"
RUNTIME="io.containerd.cwasim3.v1"

IMAGE="docker.io/keniack/fanout-wasi:latest"
BIN="/fanout-wasi.wasm"
LIB_ARG="alice-lib.wasm"

# Inputs (edit as needed)
FILES=("file_1M.txt" "file_2M.txt" "file_4M.txt" "file_6M.txt" "file_8M.txt" "file_10M.txt" "file_20M.txt" "file_40M.txt" "file_60M.txt" "file_100M.txt" "file_200M.txt" "file_300M.txt" "file_400M.txt" "file_500M.txt")
#FILES=("file_100M.txt")

# Fanout size; default 100 unless overridden by env
NUM_TASKS="${NUM_TASKS:-100}"

# Networking env
STORAGE_IP="${STORAGE_IP:-127.0.0.1:8888}"

# Output locations
RESULT_DIR="./results/fanout_cwasim1"
LOG_DIR="$RESULT_DIR/logs"
CSV="$RESULT_DIR/results.csv"

mkdir -p "$LOG_DIR"

# CSV header
if [ ! -f "$CSV" ]; then
  echo "file,num_tasks,start_iso,end_iso,elapsed_seconds,exit_code,container_name,log_path,storage_ip" > "$CSV"
fi

cleanup_all() {
  # Best-effort cleanup of leftover tasks/containers
  sudo ctr -n "$NAMESPACE" containers list -q | xargs -r sudo ctr -n "$NAMESPACE" task kill --signal SIGKILL >/dev/null 2>&1 || true
  sudo ctr -n "$NAMESPACE" containers list -q | xargs -r sudo ctr -n "$NAMESPACE" containers rm >/dev/null 2>&1 || true
}
trap 'cleanup_all' EXIT

for file in "${FILES[@]}"; do
  echo "=== ROUND: file=${file}, NUM_TASKS=${NUM_TASKS} ==="

  safe_file="${file//_/-}"
  safe_file="${safe_file%.txt}"
  ts="$(date +%Y%m%d-%H%M%S)"

  cname="m1f-${NUM_TASKS}-${safe_file}"
  log_path="$LOG_DIR/${ts}-${safe_file}-${NUM_TASKS}.log"

  start_ns="$(date +%s%N)"
  start_iso="$(date -Iseconds)"

  # Run the fanout driver (single container) and capture logs/RC
  if sudo ctr -n "$NAMESPACE" run --rm \
      --runtime="$RUNTIME" \
      --net-host=true \
      --env STORAGE_IP="$STORAGE_IP" \
      --env NUM_TASKS="$NUM_TASKS" \
      "$IMAGE" "$cname" \
      "$BIN" "$LIB_ARG" "$file" >"$log_path" 2>&1
  then
    rc=0
  else
    rc=$?
  fi

  end_ns="$(date +%s%N)"
  end_iso="$(date -Iseconds)"
  elapsed="$(awk -v s="$start_ns" -v e="$end_ns" 'BEGIN { printf "%.6f", (e-s)/1000000000 }')"

  # Record CSV row
  echo "\"$file\",\"$NUM_TASKS\",\"$start_iso\",\"$end_iso\",\"$elapsed\",\"$rc\",\"$cname\",\"$log_path\",\"$STORAGE_IP\"" >> "$CSV"

  echo "  log: $log_path"
  echo "  rc : $rc"
  echo

  # Between-round cleanup
  cleanup_all
  sleep 1
done

echo "All files have been processed."
echo "CSV summary -> $CSV"
