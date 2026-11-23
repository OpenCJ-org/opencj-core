# The established builder supplies the same compiler and native dependencies as development.
ARG BUILDER_IMAGE=opencj-builder:beta-0.1.0
FROM ${BUILDER_IMAGE} AS build
COPY . /workspace
ARG SOURCE_REVISION
ARG ENGINE_REVISION
RUN cd /workspace/cod4x-server \
    && mkdir -p bin obj lib \
    && make clean_all \
    && make DEBUG=true BUILD_REVISION="${ENGINE_REVISION}" BUILD_BRANCH=release BUILD_NUMBER=0 \
    && ldd bin/cod4x18_dedrun

FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN dpkg --add-architecture i386 \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
       libmysqlclient21:i386 libstdc++6:i386 zlib1g:i386 ca-certificates python3 openssh-client \
    && rm -rf /var/lib/apt/lists/*
ARG SOURCE_REVISION
LABEL org.opencontainers.image.source="https://github.com/OpenCJ-org/opencj-core" \
      org.opencontainers.image.version="beta-0.1.0" \
      org.opencontainers.image.revision="${SOURCE_REVISION}"
COPY --from=build /workspace/cod4x-server/bin/cod4x18_dedrun /opt/opencj/server
COPY server-gsc /opt/opencj/scripts
COPY dev-tools/setup/runtime.py /opt/opencj/runtime.py
COPY LICENSE /opt/opencj/licenses/LICENSE
COPY cod4x-server/License.md cod4x-server/copying.md cod4x-server/README.md /opt/opencj/licenses/engine/
# Preserve file-specific upstream notices and the exact source used for this local build.
COPY . /opt/opencj/source
COPY docs/reference/licensing.md /opt/opencj/licenses/licensing.md
COPY VERSION /opt/opencj/VERSION
WORKDIR /runtime
ENV LD_LIBRARY_PATH=/game HOME=/tmp
ENTRYPOINT ["python3", "/opt/opencj/runtime.py"]
