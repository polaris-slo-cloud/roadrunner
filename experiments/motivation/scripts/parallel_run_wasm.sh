#!/bin/bash
set -e

IMAGE="docker.io/keniack/image-resize-wasm:latest"
BINARY_PATH="/image-resize-wasm.wasm"
RUNTIME="io.containerd.wasmedge.v1"
MOUNT_DST="/"  # Match preopened path for "/resized.jpg"
NUM_CONTAINERS=5

# Cleanup
echo "Cleaning up snapshots and image..."
sudo ctr -n k8s.io snapshot ls | awk 'NR>1 {print $1}' | tac | while read snap; do
    sudo ctr -n k8s.io snapshot rm "$snap" 2>/dev/null || true
done
sudo ctr -n k8s.io images rm "$IMAGE" 2>/dev/null || true

# Pull + Unpack with log capture
PULL_LOG=$(mktemp)
echo "Pulling image..."
start_pull=$(date +%s%3N)
sudo ctr -n k8s.io image pull "$IMAGE" | tee "$PULL_LOG"
end_pull=$(date +%s%3N)
pull_plus_unpack=$((end_pull - start_pull))

# Parse unpack time
unpack_line=$(grep -A1 '^unpacking ' "$PULL_LOG" | tail -n1)
unit=$(echo "$unpack_line" | grep -oP 'ms|s$' || echo "ms")
value=$(echo "$unpack_line" | grep -oP '\d+\.\d+')
if [[ "$unit" == "s" ]]; then
  unpack_ms=$(awk "BEGIN {printf(\"%.0f\", $value * 1000)}")
else
  unpack_ms=$(awk "BEGIN {printf(\"%.0f\", $value)}")
fi
rm "$PULL_LOG"
pull_only=$((pull_plus_unpack - unpack_ms))

# Launch containers in parallel
declare -a pids
declare -a durations

echo "Launching $NUM_CONTAINERS WASM containers..."
for i in $(seq 1 $NUM_CONTAINERS); do
    (
        CONTAINER_NAME="wasmrun-$(date +%s%3N)-$RANDOM"
        start=$(date +%s%3N)
        sudo ctr -n k8s.io run --rm \
            --runtime="$RUNTIME" \
            "$IMAGE" "$CONTAINER_NAME" "$BINARY_PATH" > /dev/null
        end=$(date +%s%3N)
        echo "$((end - start))" > "/tmp/wasm_container_duration_$i"
    ) &
    pids+=($!)
done

# Wait for all
for pid in "${pids[@]}"; do
    wait "$pid"
done

# Collect durations
total=0
min=99999999
max=0
for i in $(seq 1 $NUM_CONTAINERS); do
    d=$(cat "/tmp/wasm_container_duration_$i")
    durations+=($d)
    total=$((total + d))
    if (( d < min )); then min=$d; fi
    if (( d > max )); then max=$d; fi
    rm "/tmp/wasm_container_duration_$i"
done
avg=$((total / NUM_CONTAINERS))

# Final output
echo
echo "WASM Parallel Execution Summary:"
echo "Pull only       : ${pull_only} ms"
echo "Unpack only     : ${unpack_ms} ms"
echo "WASM containers : $NUM_CONTAINERS"
echo "   - Min duration  : ${min} ms"
echo "   - Max duration  : ${max} ms"
echo "   - Avg duration  : ${avg} ms"
echo "Total run time  : ${total} ms (sum of all containers)"

