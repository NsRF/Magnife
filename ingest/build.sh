#!/bin/zsh
# Builds ingest/bin/magnife-ingest as a universal (arm64 + amd64) binary.
# CGO is off (modernc.org/sqlite), so amd64 cross-compiles without a C
# toolchain. -B gobuildid gives each slice an LC_UUID, which macOS privacy
# machinery needs (docs/research/platform.md).
set -euo pipefail

cd "${0:A:h}"
out=bin/magnife-ingest
mkdir -p bin

for arch in arm64 amd64; do
	CGO_ENABLED=0 GOOS=darwin GOARCH=$arch go build -trimpath \
		-ldflags "-s -w -B gobuildid" -o "bin/magnife-ingest-$arch" ./cmd/magnife-ingest
done
lipo -create -output "$out" bin/magnife-ingest-arm64 bin/magnife-ingest-amd64
rm bin/magnife-ingest-arm64 bin/magnife-ingest-amd64

lipo -info "$out"
for arch in arm64 x86_64; do
	uuid=$(otool -arch $arch -l "$out" | awk '/LC_UUID/ { getline; getline; print $2 }')
	echo "$arch LC_UUID: ${uuid:-missing}"
	[[ -n $uuid ]] || { echo "error: $arch slice has no LC_UUID" >&2; exit 1 }
done
