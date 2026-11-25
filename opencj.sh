#!/usr/bin/env bash
# OpenCJ server administration: install, status, settings, upgrades, backups and maps.
# After installation it is also available as `sudo opencj <command>` (a link to this file).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
release=beta-0.1.0
# Follow the system-wide link back to this checkout, so `opencj` uses its own release.
script_dir=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)

usage() {
    printf '%s\n' "OpenCJ $release server administration (Ubuntu 24.04 x86-64)" '' \
        'First installation (from the release checkout):' \
        '  sudo bash opencj.sh install                 Ask which servers to create, then install them' \
        '  sudo bash opencj.sh install --plan FILE     Unattended, from a private JSON plan' \
        '' \
        'Afterwards, from anywhere:' \
        '  sudo opencj status                          Everything on this machine, then what needs attention' \
        '  sudo opencj configure NAME                  Name, address, port, access, passwords, map, downloads,' \
        '                                              Discord, backups, pruning, website domains' \
        '  sudo opencj alerts                          Discord channel for alerts (sends a test message)' \
        '  sudo opencj dns                             DNS records to create, and whether they point here' \
        '  sudo opencj add-server                      Add another server to this machine' \
        '  sudo opencj maps add SOURCE | maps list     Add or update a custom map' \
        '  sudo opencj restore NAME BACKUP.sql.gz      Replace a server'"'"'s data with a backup' \
        '  sudo opencj refresh NAME                    Fresh copy of the source (for example acceptance)' \
        '  sudo opencj install                         Recheck all servers and finish interrupted work' \
        '' \
        'Upgrading (from the NEW release checkout):' \
        '  sudo bash opencj.sh upgrade' \
        '' \
        'On the external backup server:' \
        '  sudo bash opencj.sh backup-receiver --name NAME --key PUBLIC_KEY' \
        '  sudo bash opencj.sh monitor --name NAME --target game:HOST:PORT --target web:https://NAME/' \
        '                                              Alert when a game server or the website stops answering' \
        '                                              (sudo opencj alerts on the game host prints this line)' \
        '' \
        'Advanced: install --instance-dir DIR [--config FILE] [--check | --backup] for one server;' \
        'export | resume-source for migration sources. Commands never reset existing data.' \
        'Guide: docs/operations/server-administration.md'
}

command=${1:-}
case "$command" in
    ''|-h|--help|help)
        usage
        exit 0
        ;;
    install|add-server|status|configure|alerts|dns|maps|restore|refresh|upgrade|backup-receiver|monitor|export|resume-source)
        ;;
    *)
        echo "Unknown command: $command" >&2
        usage >&2
        exit 2
        ;;
esac

source /etc/os-release
if [[ "$ID" != ubuntu || "$VERSION_ID" != 24.04 || "$(uname -m)" != x86_64 ]]; then
    echo 'This release supports Ubuntu 24.04 LTS on x86-64.' >&2
    exit 1
fi
privilege=()
if [[ $(id -u) != 0 ]]; then
    privilege=(sudo)
fi
if ! command -v git >/dev/null || ! command -v python3 >/dev/null || ! command -v rsync >/dev/null; then
    "${privilege[@]}" apt-get update
    "${privilege[@]}" apt-get install -y git python3 ca-certificates curl rsync openssh-client passwd
fi
if [[ -f "$script_dir/dev-tools/setup/install.py" ]]; then
    source_dir=$script_dir
else
    source_dir=${OPENCJ_SOURCE_DIR:-/opt/opencj/releases/$release}
    if [[ -e "$source_dir" ]]; then
        echo 'Will not overwrite an existing source directory. Run its opencj.sh instead.' >&2
        exit 1
    fi
    # Clone only a published release tag. Never silently install a moving branch.
    git clone --branch "$release" --single-branch \
        https://github.com/OpenCJ-org/opencj-core.git "$source_dir"
fi
setup=$source_dir/dev-tools/setup

# The external backup server only stores files and watches from outside; it needs
# neither Docker nor the game.
if [[ "$command" == backup-receiver ]]; then
    exec python3 -B "$setup/offsite.py" "$@"
fi
if [[ "$command" == monitor ]]; then
    exec python3 -B "$setup/monitor.py" "$@"
fi
if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
    bash "$source_dir/dev-tools/scripts/install-host.sh"
fi
case "$command" in
    install)
        shift
        for argument in "$@"; do
            if [[ "$argument" == --instance-dir || "$argument" == --instance-dir=* ]]; then
                exec python3 -B "$setup/install.py" "$@"
            fi
        done
        exec python3 -B "$setup/host_plan.py" "$@"
        ;;
    add-server)
        exec python3 -B "$setup/host_plan.py" "$@"
        ;;
    export|resume-source)
        exec python3 -B "$setup/migration.py" "$@"
        ;;
    maps)
        exec python3 -B "$setup/maps.py" "$@"
        ;;
    *)
        exec python3 -B "$setup/manage.py" "$@"
        ;;
esac
