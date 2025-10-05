# Installation Guide

This guide explains how to use the provided installer script to set up:
- Rust
- containerd
- Docker Engine + CLI
- WasmEdge 0.11.2 (in /opt/wasmedge and added to PATH)
- Redis server
- CRI-tools (crictl)
- TWO runtimes installed to /usr/local/bin:
    * /usr/local/bin/containerd-shim-cwasi-v1 (Roadrunner)
    * /usr/local/bin/containerd-shim-wasmedge-v1 (Wasmedge)
- containerd is configured so it can find shims in /usr/local/bin

## Supported OS

- Ubuntu 20.04 / 22.04 (amd64)

## Prerequisites

- Run as root (or with sudo).
- Internet access.

## Inputs
If you want the script to install your shim binaries, export these BEFORE running:

export SHIM_CWASI_SRC=experiments/evaluation/binaries/containerd-shim-cwasi-v1
export SHIM_WASMEDGE_SRC=experiments/evaluation/binaries/wasmedge/ (See wasmedge instrunctions for source compilation) 

Both files must exist and be executable. If not provided, shim copy steps will not be complete.

## How to Run the Installer

1) Make it executable:
   chmod +x ./quick-install.sh

2) (Optional) Provide shim paths:
   export SHIM_CWASI_SRC=experiments/evaluation/binaries/containerd-shim-cwasi-v1
   export SHIM_WASMEDGE_SRC=experiments/evaluation/binaries/wasmedge/

3Run as root:
   sudo ./quick-install.sh

## What the Script Does 
- Installs Rust via rustup and sources your cargo environment.
- Installs containerd and starts/enables it.
- Installs Docker Engine + CLI (and adds you to the docker group).
- Downloads and installs WasmEdge 0.11.2 into /opt, adds /opt/wasmedge/bin to PATH.
- Installs Redis and CRI-tools (crictl) and points crictl to containerd.
- Copies shims to:
  /usr/local/bin/containerd-shim-cwasi-v1
  /usr/local/bin/containerd-shim-wasmedge-v1
- Ensures systemd’s containerd service has /usr/local/bin in PATH.
- Restarts containerd.

## Post-Install Notes
- The script may add your user to the “docker” group. Log out and log back in (or run `newgrp docker`)
  for the change to take effect.
- WasmEdge PATH is written to /etc/profile.d/wasmedge.sh. Open a new shell or source it:
  source /etc/profile.d/wasmedge.sh

## Verify Installation

Check versions (these should not error):
```
containerd --version
ctr version
docker --version
wasmedge --version
redis-server --version
crictl --version
```
Confirm shims are present:
```
ls -l /usr/local/bin/containerd-shim-cwasi-v1
ls -l /usr/local/bin/containerd-shim-wasmedge-v1
```
Quick Tests (adjust if needed)
------------------------------
1) WasmEdge runtime test:
```
sudo ctr -n k8s.io run --rm \
--runtime io.containerd.wasmedge.v1 \
docker.io/wasmedge/example-wasi:latest \
test-wasmedge \
/wasi_example_main.wasm 12345
```
2) RoadRunner runtime test:
```
sudo ctr -n k8s.io run --rm \
--runtime io.containerd.cwasi.v1 \
docker.io/wasmedge/example-wasi:latest \
test-cwasi \
/wasi_example_main.wasm 12345
```
You should see example output as follows
```
Random number: 482122638
Random bytes: [225, 30, 239, 250, 146, 129, 102, 223, 136, 134, 239, 10, 253, 126, 164, 185, 49, 21, 179, 102, 239, 58, 206, 204, 248, 26, 74, 66, 122, 92, 220, 30, 72, 234, 42, 158, 129, 161, 130, 164, 34, 9, 172, 128, 58, 122, 187, 253, 133, 193, 63, 36, 70, 53, 195, 45, 119, 92, 157, 242, 115, 212, 117, 198, 152, 92, 75, 231, 228, 220, 219, 226, 76, 161, 83, 235, 122, 63, 201, 5, 13, 231, 97, 17, 10, 17, 173, 176, 114, 220, 33, 92, 244, 85, 105, 175, 106, 61, 133, 3, 16, 89, 36, 197, 140, 73, 47, 26, 165, 255, 165, 100, 80, 100, 21, 247, 212, 230, 212, 73, 105, 125, 151, 229, 164, 203, 11, 86]
Printed from wasi: This is from a main function
This is from a main function
The env vars are as follows.
PATH: /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
The args are as follows.
/wasi_example_main.wasm
50000000
File content is This is in a file
```

Troubleshooting
---------------
- "runtime not found":
    * Ensure shim binaries exist at `/usr/local/bin/` and are executable.
    * Ensure containerd has been restarted after installation.
    * Confirm the PATH override for the containerd service (see "Verify Installation").
- Docker permission denied:
    * Re-login or run: newgrp docker

Uninstall (optional)
--------------------
Remove shims:
```
sudo rm -f /usr/local/bin/containerd-shim-cwasi-v1
sudo rm -f /usr/local/bin/containerd-shim-wasmedge-v1
```
Remove WasmEdge PATH and install:
```
sudo rm -f /etc/profile.d/wasmedge.sh
sudo rm -f /opt/wasmedge
# Optionally remove extracted WasmEdge directory:
ls -d /opt/WasmEdge-*/ | xargs -r sudo rm -rf
```
