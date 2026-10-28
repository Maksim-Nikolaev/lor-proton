#!/usr/bin/env bash
set -euo pipefail

ge_tag="GE-Proton9-27"
revision="LoR1"
name="$ge_tag-$revision"
repo="$(cd "$(dirname "$0")" && pwd)"
build="$repo/build"
dist="$repo/dist"
base=""
dlls=(combase kernelbase ole32 uiautomationcore user32)

usage() {
  echo "usage: ./build.sh [--base <existing $ge_tag directory>]"
  echo "Without --base, the official $ge_tag release is downloaded and its checksum verified."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)
      base="$(cd "${2:?--base needs a directory}" && pwd)"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
done

in_container() {
  docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -e GE_TAG="$ge_tag" \
    -v "$repo:/repo:ro" -v "$build:/build" lor-proton-build "$@"
}

mkdir -p "$build" "$dist"

echo "==> Building the build container"
docker build -q -t lor-proton-build "$repo/docker" > /dev/null

echo "==> Preparing Wine source of $ge_tag with GE-Proton and LoR patches"
in_container bash /repo/scripts/prepare-wine.sh > "$build/prepare.log" 2>&1 || {
  echo "Preparing the source failed, see $build/prepare.log" >&2
  exit 1
}

echo "==> Compiling ${dlls[*]}"
in_container bash /repo/scripts/build-dlls.sh > "$build/build-dlls.log" 2>&1 || {
  echo "Compiling failed, see $build/build-dlls.log" >&2
  exit 1
}
in_container sh -c 'for dll in /build/dlls/*.dll; do x86_64-w64-mingw32-strip --strip-debug "$dll"; done'

if [[ -z "$base" ]]; then
  echo "==> Downloading $ge_tag"
  url="https://github.com/GloriousEggroll/proton-ge-custom/releases/download/$ge_tag/$ge_tag.tar.gz"
  curl -fL -o "$build/$ge_tag.tar.gz" "$url"
  curl -fsSL -o "$build/$ge_tag.sha512sum" "$url.sha512sum" 2>/dev/null \
    || curl -fsSL -o "$build/$ge_tag.sha512sum" "${url%.tar.gz}.sha512sum"
  (cd "$build" && sed "s#[^ ]*$ge_tag.tar.gz#$ge_tag.tar.gz#" "$ge_tag.sha512sum" | sha512sum -c -)
  rm -rf "$build/$ge_tag"
  tar -xzf "$build/$ge_tag.tar.gz" -C "$build"
  base="$build/$ge_tag"
fi

echo "==> Assembling $name from $base"
runner="$dist/$name"
rm -rf "$runner"
cp -a "$base" "$runner"

target=""

for candidate in files/lib64/wine/x86_64-windows files/lib/wine/x86_64-windows; do
  if [[ -d "$runner/$candidate" ]]; then
    target="$runner/$candidate"
    break
  fi
done

if [[ -z "$target" ]]; then
  echo "No x86_64-windows DLL directory in $base" >&2
  exit 1
fi

for dll in "${dlls[@]}"; do
  cp "$build/dlls/$dll.dll" "$target/$dll.dll"
done

rm -rf "$runner/__pycache__"
sed -i "s/^CURRENT_PREFIX_VERSION=\"$ge_tag\"$/CURRENT_PREFIX_VERSION=\"$name\"/" "$runner/proton"
sed -i "s/\"$ge_tag\"/\"$name\"/g" "$runner/compatibilitytool.vdf"
sed -i "s/ $ge_tag$/ $name/" "$runner/version"

grep -q "CURRENT_PREFIX_VERSION=\"$name\"" "$runner/proton" || {
  echo "Could not set CURRENT_PREFIX_VERSION in $runner/proton" >&2
  exit 1
}

echo "==> Packing $dist/$name.tar.gz"
tar -czf "$dist/$name.tar.gz" -C "$dist" "$name"
(cd "$dist" && sha512sum "$name.tar.gz" > "$name.sha512sum")

echo "Done: $runner"
