#!/usr/bin/env bash
# Ubuntu prerequisites, shared by development and the release installer.
set -euo pipefail
source /etc/os-release
if [[ "$ID" != ubuntu || "$VERSION_ID" != 24.04 ]]; then
    echo 'This installer targets Ubuntu 24.04.' >&2
    exit 1
fi
if [[ "$(uname -m)" != x86_64 ]]; then
    echo 'An x86_64 host is required.' >&2
    exit 1
fi
privilege=()
if [[ $(id -u) != 0 ]]; then
    privilege=(sudo)
fi
"${privilege[@]}" apt-get update
"${privilege[@]}" apt-get install -y git python3 ca-certificates curl
if ! command -v docker >/dev/null; then
    "${privilege[@]}" install -m 0755 -d /etc/apt/keyrings
    "${privilege[@]}" curl --proto '=https' --tlsv1.2 -fsSL \
        https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    "${privilege[@]}" chmod a+r /etc/apt/keyrings/docker.asc
    printf '%s\n' 'Types: deb' 'URIs: https://download.docker.com/linux/ubuntu' \
        'Suites: noble' 'Components: stable' 'Architectures: amd64' \
        'Signed-By: /etc/apt/keyrings/docker.asc' \
        | "${privilege[@]}" tee /etc/apt/sources.list.d/docker.sources >/dev/null
    "${privilege[@]}" apt-get update
    "${privilege[@]}" apt-get install -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
fi
if ! docker compose version >/dev/null 2>&1; then
    echo 'Existing Docker lacks Compose v2+. Install its matching Compose plugin; existing packages were preserved.' >&2
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    echo 'Docker is installed but not accessible. Run setup as root or configure Docker access and reconnect.' >&2
    echo 'See https://docs.docker.com/engine/install/linux-postinstall/ (Docker access grants root-level power).' >&2
    exit 1
fi
