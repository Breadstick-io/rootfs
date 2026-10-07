# bsl-vmtest:2, for qemu-test.sh: docker build -t bsl-vmtest:2 vm/test
FROM debian:trixie
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends qemu-system-arm qemu-system-x86 ipxe-qemu python3 procps zstd xvfb x11-utils >/dev/null && rm -rf /var/lib/apt/lists/*
