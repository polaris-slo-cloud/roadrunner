# Motivation Experiments

This directory reproduces the motivation experiments comparing native/containerized
functions with their Wasm counterparts, measuring end-to-end latency and throughput.
It supports any example organized under `examples/{example}/container` and `examples/{example}/wasm`.
Each experiment includes single-run and parallel-run scripts (which executes experiments multiple times to avoid biases) and stores results as CSV files for later analysis.


## PREREQUISITES

Required software:
- Linux host (Ubuntu 22.04 LTS recommended)
- Docker (for building and pushing images)
- containerd (with runtime integration)
- ctr and crictl installed
- WasmEdge runtime integrated into containerd (see root readme)


## DIRECTORY STRUCTURE

```
experiments/motivation/
├── scripts/                         
│   ├── run_{example}.sh                 # Native / container runtime
│   ├── run_wasm_{example}.sh            # WasmEdge runtime 
│   ├── parallel_run.sh                  # Parallel container runs
│   └── parallel_run_wasm.sh             # Parallel WasmEdge runs
├── results/                         # Directory containing all CSV outputs
│   ├── results-{example}-native.csv
│   └── results-{example}-wasm.csv
└── README.md                      
examples/
├── image-resize/
│    ├── container/
│    │    └── Dockerfile
│    └── wasm/
│         └── Dockerfile
└── hello-world/
```

## BUILDING IMAGES

Build and push container-based function  
(Replace {example} with your example name, e.g., image-resize or hello-world)

```
cd examples/{example}/container
sudo docker build -f Dockerfile -t docker.io/username/{example}:latest .
sudo docker push docker.io/username/{example}:latest
```
Build and push Wasm-based function

```
cd examples/{example}/wasm
sudo docker build -f Dockerfile -t docker.io/username/{example}-wasm:latest .
sudo docker push docker.io/username/{example}-wasm:latest
```

## RUNNING SINGLE EXPERIMENTS

In the current directory:

```
cd experiments/motivation
```
Execute the scripts for container and Wasm runs:

```
./run_{example}.sh
./run_wasm_{example}.sh
```
Each script will execute the function via containerd and automatically log results to the results/ directory.

Container example:
```
sudo ctr -n k8s.io run --rm --runtime=io.containerd.runc.v2 \
--net-host=true docker.io/username/{example}:latest run /{example}
```
Wasm example:
```
sudo ctr -n k8s.io run --rm --runtime=io.containerd.wasmedge.v1 \
--net-host=true docker.io/username/{example}-wasm:latest run /{example}-wasm.wasm
```

Output is printed to stdout and appended to `results/results-{example}-native.csv` and `results/results-{example}-wasm.csv`.


## RUNNING PARALLEL EXPERIMENTS

Run container-based experiment in parallel:
```
./parallel_run.sh
```
Run Wasm-based experiment in parallel:
```
./parallel_run_wasm.sh
```
Both scripts spawn multiple concurrent runs to evaluate scalability.
Results are appended to CSV logs under `results/`.


## NOTES

- Replace `{example}` with your function name (e.g., image-resize, hello-world)
- Adjust image names or container registry if necessary
- Ensure containerd namespace (`-n k8s.io`) matches your environment
- Clean previous images and runs if measurements vary unexpectedly:
```
sudo ctr -n k8s.io containers rm -f $(sudo ctr -n k8s.io containers ls -q)
sudo ctr -n k8s.io images rm -f $(sudo ctr -n k8s.io images ls -q | grep {example})
```