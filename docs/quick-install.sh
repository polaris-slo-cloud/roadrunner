#!/usr/bin/env bash
set -euo pipefail

#   export SHIM_CWASI_SRC=experiments/evaluation/binaries/containerd-shim-cwasi-v1
#   export SHIM_WASMEDGE_SRC=/path/to/containerd-shim-wasmedge-v1
SHIM_CWASI_SRC="${SHIM_CWASI_SRC:-}"
SHIM_WASMEDGE_SRC="${SHIM_WASMEDGE_SRC:-}"

SHIM_CWASI_DST="/usr/local/bin/containerd-shim-cwasi-v1"
SHIM_WASMEDGE_DST="/usr/local/bin/containerd-shim-wasmedge-v1"

CONTAINERD_CFG="/etc/containerd/config.toml"
NAMESPACE="k8s.io"

# --- Rust ---
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
# shellcheck disable=SC1091
source "$HOME/.cargo/env"

# --- containerd ---
sudo apt-get update
sudo apt-get install -y curl ca-certificates gnupg lsb-release
sudo apt-get install -y containerd
sudo systemctl enable --now containerd

# --- Docker (Engine & CLI) ---
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
# (optional) run docker as non-root
if ! id -nG "$USER" | grep -qw docker; then
  sudo usermod -aG docker "$USER" || true
  echo "Added $USER to docker group (log out/in or: newgrp docker)."
fi

# --- WasmEdge 0.11.2 ---
tmpdir="$(mktemp -d)"
(
  cd "$tmpdir"
  curl -LO https://github.com/WasmEdge/WasmEdge/releases/download/0.11.2/WasmEdge-0.11.2-ubuntu20.04_x86_64.tar.gz
  sudo tar -xzf WasmEdge-0.11.2-ubuntu20.04_x86_64.tar.gz -C /opt
  extracted_dir="$(tar -tzf WasmEdge-0.11.2-ubuntu20.04_x86_64.tar.gz | head -1 | cut -f1 -d"/")"
  sudo ln -sfn "/opt/${extracted_dir}" /opt/wasmedge
)
echo 'export PATH=/opt/wasmedge/bin:$PATH' | sudo tee /etc/profile.d/wasmedge.sh >/dev/null
# shellcheck disable=SC1091
source /etc/profile.d/wasmedge.sh
rm -rf "$tmpdir"

# --- Redis ---
sudo apt-get install -y redis-server
sudo systemctl enable --now redis-server

# --- CRI-tools (crictl) ---
sudo apt-get install -y cri-tools
sudo mkdir -p /etc/crictl
echo "runtime-endpoint: unix:///run/containerd/containerd.sock" | sudo tee /etc/crictl.yaml >/dev/null

# --- Install shims into /usr/local/bin ---
if [[ -n "$SHIM_CWASI_SRC" ]]; then
  if [[ -x "$SHIM_CWASI_SRC" ]]; then
    echo "Installing cwasi shim: $SHIM_CWASI_SRC -> $SHIM_CWASI_DST"
    sudo install -m 0755 "$SHIM_CWASI_SRC" "$SHIM_CWASI_DST"
  else
    echo "ERROR: SHIM_CWASI_SRC is not executable: $SHIM_CWASI_SRC" >&2
    exit 1
  fi
else
  echo "NOTE: SHIM_CWASI_SRC not set; skipping cwasi shim install."
fi

if [[ -n "$SHIM_WASMEDGE_SRC" ]]; then
  if [[ -x "$SHIM_WASMEDGE_SRC" ]]; then
    echo "Installing WasmEdge shim: $SHIM_WASMEDGE_SRC -> $SHIM_WASMEDGE_DST"
    sudo install -m 0755 "$SHIM_WASMEDGE_SRC" "$SHIM_WASMEDGE_DST"
  else
    echo "ERROR: SHIM_WASMEDGE_SRC is not executable: $SHIM_WASMEDGE_SRC" >&2
    exit 1
  fi
else
  echo "NOTE: SHIM_WASMEDGE_SRC not set; skipping WasmEdge shim install."
fi

# Ensure containerd service sees /usr/local/bin in PATH (so it can find both shims)
sudo mkdir -p /etc/systemd/system/containerd.service.d
sudo tee /etc/systemd/system/containerd.service.d/override.conf >/dev/null <<'EOF'
[Service]
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EOF
sudo systemctl daemon-reload

sudo systemctl restart containerd

# --- Quick sanity prints ---
echo "== Versions =="
containerd --version || true
ctr version || true
docker --version || true
wasmedge --version || true
redis-server --version || true
crictl --version || true

echo
echo "Setup complete."
echo "cwasi shim     : $SHIM_CWASI_DST  $( [[ -x $SHIM_CWASI_DST ]] && echo '[installed]' || echo '[missing]' )"
echo "wasmedge shim  : $SHIM_WASMEDGE_DST  $( [[ -x $SHIM_WASMEDGE_DST ]] && echo '[installed]' || echo '[missing]' )"
echo "Containerd config: $CONTAINERD_CFG"
echo
echo "Quick tests (adjust as needed):"
echo "  # WasmEdge runtime:"
echo "  sudo ctr -n $NAMESPACE run --rm --runtime io.containerd.wasmedge.v1 \\"
echo "    docker.io/wasmedge/example-wasi:latest test-wasmedge /wasi_example_main.wasm 12345"
echo
echo "  # Roadrunner runtime:"
sudo "  ctr -n $NAMESPACE run --rm --runtime io.containerd.wasmedge.v1 \\"
echo "    docker.io/wasmedge/example-wasi:latest test-wasmedge /wasi_example_main.wasm 12345"