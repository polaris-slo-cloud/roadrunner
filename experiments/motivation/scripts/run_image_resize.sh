#!/bin/bash
set -e

# === Configuration ===
IMAGE="docker.io/keniack/image-resize-native:latest"
CONTAINER_NAME="run-$(date +%s%3N)-$RANDOM"
BINARY_PATH="/usr/local/bin/image-resize"
RESULTS_DIR="$(dirname "$0")/results"
RESULTS_FILE="${RESULTS_DIR}/results-native.csv"

# === Prepare results directory ===
mkdir -p "$RESULTS_DIR"
if [ ! -f "$RESULTS_FILE" ]; then
    echo "timestamp,image,pull_only_ms,unpack_ms,run_ms,total_ms" > "$RESULTS_FILE"
fi

# === Cleanup ===
echo "Cleaning up snapshots and image..."
sudo ctr -n k8s.io snapshot ls | awk 'NR>1 {print $1}' | tac | while read snap; do
    sudo ctr -n k8s.io snapshot rm "$snap" 2>/dev/null || true
done
sudo ctr -n k8s.io images rm "$IMAGE" 2>/dev/null || true

# === Pull + Unpack ===
PULL_LOG=$(mktemp)
echo "Pulling image..."
start_pull=$(date +%s%3N)
sudo ctr -n k8s.io image pull "$IMAGE" | tee "$PULL_LOG"
end_pull=$(date +%s%3N)
pull_plus_unpack=$((end_pull - start_pull))

# Parse unpack time
unpack_line=$(grep -A1 '^unpacking ' "$PULL_LOG" | tail -n1)
unit=$(echo "$unpack_line" | grep -oE 'ms|s$' || echo "ms")
value=$(echo "$unpack_line" | grep -oE '[0-9]+\.[0-9]+')

if [[ "$unit" == "s" ]]; then
  unpack_ms=$(awk "BEGIN {printf(\"%.0f\", $value * 1000)}")
else
  unpack_ms=$(awk "BEGIN {printf(\"%.0f\", $value)}")
fi
rm "$PULL_LOG"

# Pull-only = total pull - unpack time
pull_only=$((pull_plus_unpack - unpack_ms))

# === Run container ===
echo "Running container..."
start_run=$(date +%s%3N)
sudo ctr -n k8s.io run --rm "$IMAGE" "$CONTAINER_NAME" "$BINARY_PATH"
end_run=$(date +%s%3N)
run_duration=$((end_run - start_run))

# Total duration
total_duration=$((end_run - start_pull))

# === Output ===
echo
echo "Results:"
echo "Pull only       : ${pull_only} ms"
echo "Unpack only     : ${unpack_ms} ms"
echo "Run only        : ${run_duration} ms"
echo "Total time      : ${total_duration} ms"

# === Save to CSV ===
timestamp=$(date '+%Y-%m-%d %H:%M:%S')
echo "${timestamp},${IMAGE},${pull_only},${unpack_ms},${run_duration},${total_duration}" >> "$RESULTS_FILE"

echo "Results saved to ${RESULTS_FILE}"
