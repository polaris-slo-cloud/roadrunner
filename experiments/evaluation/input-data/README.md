This directory is a simple storage that serves static files to functions, so we can measure pure HTTP overhead (transfer + serialzation) separate from compute.

What it is
- A tiny Rust/warp server (see src/main.rs) exposes the files in `./storage/files` at the route /files on port 8888.
- Clients/functions fetch these artifacts over HTTP to benchmark network/HTTP cost.

Payloads
- To create the payloads execute `./make-payloads.sh`
How it works
- Start the server: `cargo run`
- It binds to `0.0.0.0:8888`
- Files placed in ./storage/files are available at:` http://HOST:8888/files/<FILENAME>`

Example
- Place a file at: `./storage/files/10MB.txt`
- Fetch it: `curl -v http://127.0.0.1:8888/files/10MB.txt -o /dev/null`

Artifacts
- Payload files can just repeat the string: "Artifact for middleware evaluation"
- Use any sizes needed for experiments (e.g., 1MB, 10MB, 100MB, etc.).

Notes
- This storage is for benchmarking HTTP overhead only; no authentication is provided.
- Don’t expose publicly without proper access controls.
