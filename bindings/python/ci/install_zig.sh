#!/usr/bin/env bash
# Install a pinned Zig 0.17 into /opt/zig inside a manylinux build container (used by
# cibuildwheel's `before-all` on Linux). macOS/Windows builds use the host Zig from setup-zig.
set -euo pipefail

ZIG_VERSION="${ZIG_VERSION:-0.17.0}"
DEST="/opt/zig"

arch="$(uname -m)"
case "$arch" in
  x86_64|amd64) za="x86_64" ;;
  aarch64|arm64) za="aarch64" ;;
  *) echo "unsupported arch: $arch" >&2; exit 1 ;;
esac

# Official SHA-256 checksums from https://ziglang.org/download/index.json. The download is
# verified against these before anything is extracted or executed — bumping ZIG_VERSION
# requires adding its checksums here, and an unknown version fails closed.
case "${ZIG_VERSION}-${za}" in
  0.17.0-x86_64) expected_sha256="1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026" ;;
  0.17.0-aarch64) expected_sha256="9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8" ;;
  *)
    echo "no pinned SHA-256 for Zig ${ZIG_VERSION} on ${za}; add it from ziglang.org/download/index.json" >&2
    exit 1
    ;;
esac

mkdir -p "$DEST"
cd /tmp

# The release filename layout changed across Zig versions; try both known forms.
candidates=(
  "zig-${za}-linux-${ZIG_VERSION}"
  "zig-linux-${za}-${ZIG_VERSION}"
)

ok=0
for base in "${candidates[@]}"; do
  url="https://ziglang.org/download/${ZIG_VERSION}/${base}.tar.xz"
  echo "trying $url"
  if curl -fsSL "$url" -o zig.tar.xz; then
    echo "${expected_sha256}  zig.tar.xz" | sha256sum -c -
    tar -xJf zig.tar.xz
    cp -r "${base}/." "$DEST/"
    ok=1
    break
  fi
done

if [ "$ok" -ne 1 ]; then
  echo "failed to download Zig ${ZIG_VERSION}" >&2
  exit 1
fi

"$DEST/zig" version
