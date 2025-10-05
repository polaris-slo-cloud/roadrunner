# Roadrunner

Roadrunner is a minimal-copy, serialization-free data transfer shim for WebAssembly-based serverless functions.
It accelerates inter-function communication by bypassing expensive serialization/deserialization and reducing unnecessary memory copies between user space and kernel space, achieving near-native performance for Wasm serverless functions.

This is the source code repository for the Roadrunner prototype, described in our academic publication:
_Roadrunner: Accelerating Data Delivery to WebAssembly-Based Serverless Functions_, accepted at the 26th International Middleware Conference (Middleware 2025) in Nashville, USA.
Details on the architecture, mechanisms, and evaluation can be found in the paper.

If you would like to cite our work, you can use the plain text or BibTeX below:

```
C. Marcelino, T. Pusztai, and S. Nastic, “Roadrunner: Accelerating Data Delivery to WebAssembly-Based Serverless Functions,” in 26th International Middleware Conference (Middleware), 2025.
```

```
@inproceedings{Roadrunner2025,
  author = {Marcelino, Cynthia and Pusztai, Thomas and Nastic, Stefan},
  title = {Roadrunner: Accelerating Data Delivery to WebAssembly-Based Serverless Functions},
  booktitle = {Proceedings of the 26th International Middleware Conference (Middleware)},
  year = {2025}
}
```
## Motivation

In serverless computing, functions are stateless and typically exchange data through remote services (e.g., object storage, KVS, HTTP). This requires serialization and multiple copies between user and kernel space, which significantly increases latency and resource consumption.

While WebAssembly (Wasm) offers lightweight isolation and near-native execution speed, its reliance on the WebAssembly System Interface (WASI) introduces additional overhead for host interactions. This makes inter-function communication a critical bottleneck in Wasm-based serverless workflows.

Roadrunner addresses this bottleneck by enabling direct, serialization-free, minimal-copy communication between Wasm functions.

## Roadrunner Prototype


This repository contains a prototype implementation of Roadrunner, written in Rust and integrated with the WasmEdge runtime.

It supports the following communication mechanisms:

* User-space transfers: via WasmEdge linear memory APIs
* Kernel-space transfers: via UNIX sockets
* Network transfers: via Linux syscalls `splice` and `vmsplice`

## Repository Structure

```
.
├── README.md
├── LICENSE
├── .gitignore
├── .gitmodules
├── app/                         # Core crate (runtime + utils)
│   ├── Cargo.toml
│   ├── Cargo.lock
│   ├── src/
│   │   ├── main.rs
│   │   ├── lib.rs
│   │   ├── runtime.rs
│   │   ├── data_hose.rs
│   │   ├── remote_transfer.rs
│   │   └── utils/
│   │       ├── oci_utils.rs
│   │       └── snapshot_utils.rs
│   └── tests/
│       ├── oci_utils_tests.rs
│       ├── snapshot_utils_tests.rs
│       ├── data_hose_tests.rs
│       └── remote_transfer_tests.rs
├── docs/
│   └── install.md               # Extra installation notes
├── experiments/
│   ├── evaluation/              # Main evaluation harness
│   │   ├── input-data/
│   │   │   ├── README.md
│   │   │   └── make-payloads.sh # Generates file_*M.txt payloads
│   │   ├── binaries/            # Prebuilt containerd shims (for convenience)
│   │   ├── scripts/
│   │   │   ├── intra-inter-node-wasmedge.sh
│   │   │   ├── intra-inter-node-container.sh
│   │   │   ├── roadrunner-embedded.sh
│   │   │   ├── roadrunner-kernel-mode.sh
│   │   │   └── roadrunner-net-mode.sh
│   │   └── wasmedge/            # WasmEdge source (as a submodule/overlay)
│   │       ├── .git             # (submodule)
│   │       ├── CMakeLists.txt
│   │       └── ...
│   └── motivation/              # Additional micro-benchmarks
│       ├── results/
│       │   ├── motivation-container.csv
│       │   ├── motivation-wasmedge.csv
│       │   ├── transfer-container.csv
│       │   └── transfer-wasmedge.csv
│       └── scripts/
│           ├── run_image_resize.sh
│           ├── run_wasm_image_resize.sh
│           ├── parallel_run.sh
│           └── parallel_run_wasm.sh
├── examples/                    # Runnable examples (Roadrunner, Wasm and container)
└── LICENSE

```

### Requirements:

* Ubuntu 20.04/22.04 (x86_64) ( sudo access to install packages, configure runtime shims, manage containerd).

* Rust (stable channel via rustup) — provides rustc and cargo

* Docker Engine & CLI (24.x or newer recommended)

* containerd (≥ 1.6) with CRI enabled

* CRI-tools (crictl) (≥ 1.27)

* WasmEdge v0.11.2

* Redis Server (≥ 6.x)

For full installation details see [Installation](docs/intall.md)