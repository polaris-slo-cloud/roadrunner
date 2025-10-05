#!/usr/bin/env bash
# Notes:
#   - Requires containerd (ctr) and RoadRunner kernel runtimes:
#       io.containerd.cwasi.v1   (workers / secondary function)
#       io.containerd.cwasim2.v1 (fanout driver)
#   - Saves logs and a CSV summary per file.
#   - Continues on errors; non-zero exit codes are recorded in the CSV.

set -u
set -o pipefail

# ----- root check -----
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

# ---------- Config ----------
NAMESPACE="k8s.io"
RUNTIME_WORKER="io.containerd.cwasi.v1"     # cwasi secondary function (func_b)
RUNTIME_DRIVER="io.containerd.cwasim2.v1"   # fanout driver (func_a)

# Images/binaries
WORKER_IMAGE="docker.io/keniack/alice-lib:latest"
WORKER_BIN="/alice-lib.wasm"

DRIVER_IMAGE="docker.io/keniack/fanout-wasi:latest"
DRIVER_BIN="/fanout-wasi.wasm"
DRIVER_LIB_ARG="alice-lib.wasm"

# Inputs — full file loop
FILES=("file_1M.txt" "file_2M.txt" "file_4M.txt" "file_6M.txt" "file_8M.txt" "file_10M.txt" \
       "file_20M.txt" "file_40M.txt" "file_60M.txt" "file_100M.txt" "file_200M.txt" \
       "file_300M.txt" "file_400M.txt" "file_500M.txt")

# NUM_TASKS: positional arg > env > default
NUM_TASKS="${1:-${NUM_TASKS:-1}}"

# Networking env (override with env if needed)
STORAGE_IP="${STORAGE_IP:-127.0.0.1:8888}"

# Output locations
RESULT_DIR="./results/fanout_roadrunner_kernel"
LOG_DIR="$RESULT_DIR/logs"
CSV="$RESULT_DIR/results.csv"

mkdir -p "$LOG_DIR"

# CSV header
if [ ! -f "$CSV" ]; then
  echo "file,num_tasks,start_iso,end_iso,elapsed_seconds,driver_exit_code,worker_failures,driver_name,worker_names,driver_log,workers_log_dir,storage_ip" > "$CSV"
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

  # Names & logs
  driver_name="rk-driver-${NUM_TASKS}-${safe_file}"
  driver_log="$LOG_DIR/${ts}-${safe_file}-driver.log"
  workers_dir="$LOG_DIR/${ts}-${safe_file}-workers"
  mkdir -p "$workers_dir"

  # Start workers (func_b) in background, capture PIDs, names, logs
  worker_pids=()
  worker_names=()
  worker_failures=0

  for ((i=1; i<=NUM_TASKS; i++)); do
    wname="rk-wkr-${NUM_TASKS}-${safe_file}-${i}"
    wlog="$workers_dir/${wname}.log"
    worker_names+=("$wname")

    echo "Starting worker $i/$NUM_TASKS -> $wname"
    if sudo ctr -n "$NAMESPACE" run --rm \
        --runtime="$RUNTIME_WORKER" \
        --annotation cwasi.secondary.function=true \
        --net-host=true \
        "$WORKER_IMAGE" "$wname" \
        "$WORKER_BIN" >"$wlog" 2>&1 &
    then
      worker_pids+=("$!")
    else
      echo "WARN: failed to start worker $wname"
      worker_failures=$((worker_failures+1))
    fi
  done

  # Give workers a moment to initialize
  sleep 5

  start_ns="$(date +%s%N)"
  start_iso="$(date -Iseconds)"

  echo "Starting driver -> $driver_name (file=$file)"
  if sudo ctr -n "$NAMESPACE" run --rm \
      --runtime="$RUNTIME_DRIVER" \
      --net-host=true \
      --env STORAGE_IP="$STORAGE_IP" \
      --env NUM_TASKS="$NUM_TASKS" \
      "$DRIVER_IMAGE" "$driver_name" \
      "$DRIVER_BIN" "$DRIVER_LIB_ARG" "$file" >"$driver_log" 2>&1
  then
    driver_rc=0
  else
    driver_rc=$?
  fi

  # Wait for driver to finish (already did), then try to clean workers
  for pid in "${worker_pids[@]}"; do
    if kill -0 "$pid" >/dev/null 2>&1; then
      wait "$pid" || true
    fi
  done

  # Best-effort kill by container name as well
  for wname in "${worker_names[@]}"; do
    sudo ctr -n "$NAMESPACE" task kill --signal SIGKILL "$wname" >/dev/null 2>&1 || true
  done
  sudo ctr -n "$NAMESPACE" task kill --signal SIGKILL "$driver_name" >/dev/null 2>&1 || true

  end_ns="$(date +%s%N)"
  end_iso="$(date -Iseconds)"
  elapsed="$(awk -v s="$start_ns" -v e="$end_ns" 'BEGIN { printf "%.6f", (e-s)/1000000000 }')"

  # Record CSV
  worker_names_joined="$(IFS=';'; echo "${worker_names[*]}")"
  echo "\"$file\",\"$NUM_TASKS\",\"$start_iso\",\"$end_iso\",\"$elapsed\",\"$driver_rc\",\"$worker_failures\",\"$driver_name\",\"$worker_names_joined\",\"$driver_log\",\"$workers_dir\",\"$STORAGE_IP\"" >> "$CSV"

  echo "Logs:"
  echo "  driver : $driver_log"
  echo "  workers: $workers_dir"
  echo "  rc(driver)=$driver_rc  worker_failures=$worker_failures"
  echo

  # Between rounds cleanup
  cleanup_all
  sleep 1
done

echo "All files have been processed."
echo "CSV summary -> $CSV"
