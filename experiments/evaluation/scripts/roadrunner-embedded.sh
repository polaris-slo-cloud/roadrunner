#!/bin/bash
# Usage:
#   sudo ./run_fanout_wasi_and_save.sh
#   sudo NUM_TASKS=100 ./run_fanout_wasi_and_save.sh
#
# Notes:
#   - Uses containerd (ctr) with io.containerd.cwasim1.v1 runtime (as in your script)
#   - Keeps running even if one run fails; records exit code + timing
#   - Adjust FILES array below as needed

set -u
set -o pipefail

# ----------------- Config -----------------
STORAGE_IP="${STORAGE_IP:-127.0.0.1:8888}"
NUM_TASKS="${NUM_TASKS:-100}"

# Files to process (same naming as your storage files)
FILES=("file_10M.txt")
# Example full set:
# FILES=("file_1M.txt" "file_2M.txt" "file_4M.txt" "file_6M.txt" "file_8M.txt" "file_10M.txt" "file_20M.txt" "file_40M.txt" "file_60M.txt" "file_100M.txt" "file_200M.txt" "file_300M.txt" "file_400M.txt" "file_500M.txt")

# Container config
NAMESPACE="k8s.io"
RUNTIME="io.containerd.cwasim1.v1"
IMAGE="docker.io/keniack/fanout-wasi:latest"
BIN="/fanout-wasi.wasm"
EXTRA_ARG="alice-lib.wasm"  # your original script passed this
# ------------------------------------------

# Output locations
RESULT_DIR="./output/parallel"
LOG_DIR="$RESULT_DIR/logs"
CSV="$RESULT_DIR/results.csv"

mkdir -p "$LOG_DIR"

# CSV header
if [ ! -f "$CSV" ]; then
  echo "file,num_tasks,start_iso,end_iso,elapsed_seconds,exit_code,log_path" > "$CSV"
fi

cleanup() {
  # Kill any leftover tasks/containers quietly
  sudo ctr -n "$NAMESPACE" containers list -q | xargs -r sudo ctr -n "$NAMESPACE" task kill --signal SIGKILL >/dev/null 2>&1 || true
  sudo ctr -n "$NAMESPACE" containers list -q | xargs -r sudo ctr -n "$NAMESPACE" containers rm >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

for file in "${FILES[@]}"; do
  echo "=== ROUND: $file (NUM_TASKS=$NUM_TASKS) ==="

  # Unique name bits for container & log
  safe_file="${file//_/-}"
  safe_file="${safe_file%.txt}"
  ts="$(date +%Y%m%d-%H%M%S)"
  cname="m1f-${NUM_TASKS}-${safe_file}"
  log_path="$LOG_DIR/${ts}-${safe_file}-tasks${NUM_TASKS}.log"

  start_ns="$(date +%s%N)"
  start_iso="$(date -Iseconds)"

  # Run the job; save stdout/stderr to log file
  if sudo ctr -n "$NAMESPACE" run --rm \
      --runtime="$RUNTIME" \
      --net-host=true \
      --env STORAGE_IP="$STORAGE_IP" \
      --env NUM_TASKS="$NUM_TASKS" \
      "$IMAGE" "$cname" \
      "$BIN" "$EXTRA_ARG" "$file" >"$log_path" 2>&1; then
    rc=0
  else
    rc=$?
  fi

  end_ns="$(date +%s%N)"
  end_iso="$(date -Iseconds)"
  elapsed="$(awk -v s="$start_ns" -v e="$end_ns" 'BEGIN { printf "%.6f", (e-s)/1000000000 }')"

  # Append to CSV
  echo "\"$file\",\"$NUM_TASKS\",\"$start_iso\",\"$end_iso\",\"$elapsed\",\"$rc\",\"$log_path\"" >> "$CSV"

  # Small pause & cleanup between rounds
  sleep 1
  cleanup

  echo "Logged -> $log_path"
  echo
done

echo "All files processed."
echo "CSV summary -> $CSV"
