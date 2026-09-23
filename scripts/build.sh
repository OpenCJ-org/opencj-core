#!/usr/bin/env bash
set -euo pipefail
cd /workspace/cod4x-server
mkdir -p bin obj lib
# Header dependencies are not fully tracked by the legacy makefile.
# A clean build also avoids reusing host/compiler-specific object files.
make clean_all
make DEBUG=true
cd plugins/libcod_plugin
# Compile and link in one command so a failed build cannot link stale objects.
g++ -m32 -g -O1 -fPIC -shared -fvisibility=hidden \
    -Wno-write-strings -I/usr/include/mysql \
    -o libcod4_1_8x.so ./*.cpp -L/usr/lib/i386-linux-gnu -lmysqlclient
file_path=/workspace/dev-tools/local/runtime/plugins
mkdir -p "$file_path"
cp libcod4_1_8x.so "$file_path/libcod4_1_8x.so"
ldd /workspace/cod4x-server/bin/cod4x18_dedrun
