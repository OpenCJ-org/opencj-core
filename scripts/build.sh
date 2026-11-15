#!/usr/bin/env bash
set -euo pipefail
cd /workspace/cod4x-server
mkdir -p bin obj lib
# Header dependencies are not fully tracked by the legacy makefile.
# A clean build also avoids reusing host/compiler-specific object files.
make clean_all
make DEBUG=true
ldd /workspace/cod4x-server/bin/cod4x18_dedrun
