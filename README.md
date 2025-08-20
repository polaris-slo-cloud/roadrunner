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

## Experiments

Requirements:
* Rust (>= 1.80)
* WasmEdge runtime installed
* Linux kernel with splice/vmsplice support

Scenarios included:

* Sequential transfer – chained functions with varying payload sizes (1MB–500MB).
* Fan-out scalability – parallel function workflows under increasing load.

Results include:

* Latency
* Throughput (RPS)
* CPU and RAM usage
