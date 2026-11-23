#!/usr/bin/env bash
# One entry point for a checkout or the standalone script from a published release.
set -euo pipefail
release=beta-0.1.0
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
    printf '%s\n' 'OpenCJ beta-0.1.0 setup (Ubuntu 24.04 x86-64)' \
        'Usage: bash setup.sh [--instance-dir DIRECTORY] [--config PRIVATE_JSON] [--check | --backup]' \
        'Without --config, setup asks for server, assets, database and optional website settings.' \
        'An existing installation is checked and preserved; this command does not upgrade it.'
    exit 0
fi
source /etc/os-release
if [[ "$ID" != ubuntu || "$VERSION_ID" != 24.04 || "$(uname -m)" != x86_64 ]]; then
    echo 'This release supports Ubuntu 24.04 LTS on x86-64.' >&2
    exit 1
fi
privilege=()
if [[ $(id -u) != 0 ]]; then
    privilege=(sudo)
fi
if ! command -v git >/dev/null || ! command -v python3 >/dev/null; then
    "${privilege[@]}" apt-get update
    "${privilege[@]}" apt-get install -y git python3 ca-certificates curl
fi
if [[ -f "$script_dir/dev-tools/setup/install.py" ]]; then
    source_dir=$script_dir
else
    source_dir=${OPENCJ_SOURCE_DIR:-/opt/opencj/releases/$release}
    if [[ -e "$source_dir" ]]; then
        echo 'Standalone setup will not overwrite an existing source directory. Run its setup.sh instead.' >&2
        exit 1
    fi
    # Clone only a published release tag. Never silently install a moving branch.
    git clone --branch "$release" --single-branch \
        https://github.com/OpenCJ-org/opencj-core.git "$source_dir"
fi
if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
    bash "$source_dir/dev-tools/scripts/install-host.sh"
fi
exec python3 -B "$source_dir/dev-tools/setup/install.py" "$@"
