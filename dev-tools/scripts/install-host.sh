#!/usr/bin/env bash
# Optional Ubuntu host prerequisites. Run as your normal SSH user.
set -euo pipefail
source /etc/os-release
[[ "$ID" == ubuntu && "$VERSION_ID" == 24.04 ]] || {
    echo 'This installer targets Ubuntu 24.04.' >&2
    exit 1
}
[[ "$(uname -m)" == x86_64 ]] || {
    echo 'An x86_64 host is required.' >&2
    exit 1
}
sudo apt-get update
sudo apt-get install -y git python3 ca-certificates curl
if ! command -v docker >/dev/null; then
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    printf '%s\n' 'Types: deb' 'URIs: https://download.docker.com/linux/ubuntu' \
        'Suites: noble' 'Components: stable' 'Architectures: amd64' \
        'Signed-By: /etc/apt/keyrings/docker.asc' | sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
docker compose version
if ! docker info >/dev/null 2>&1; then
    echo 'Docker is installed but not accessible to this user. Configure Docker access, then reconnect through SSH.' >&2
    echo 'See https://docs.docker.com/engine/install/linux-postinstall/ (docker group grants root-level access).' >&2
    exit 1
fi
