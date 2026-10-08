# bsl-vmtest:3, for qemu-test.sh: docker build -t bsl-vmtest:3 vm/test (3: openssh-sftp-server, for the files test)
FROM debian:trixie
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends qemu-system-arm qemu-system-x86 ipxe-qemu python3 procps zstd xvfb x11-utils openssh-sftp-server >/dev/null && rm -rf /var/lib/apt/lists/*
