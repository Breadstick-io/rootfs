# bsl-vmtest:1, for qemu-test.sh: docker build -t bsl-vmtest:1 vm/test
FROM debian:trixie
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends qemu-system-arm qemu-system-x86 ipxe-qemu python3 procps zstd >/dev/null && rm -rf /var/lib/apt/lists/*
