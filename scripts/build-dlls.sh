#!/usr/bin/env bash
set -euo pipefail

wine="/build/src/proton-ge-custom/wine"
obj="/build/obj/wine64"
out="/build/dlls"
dlls=(combase kernelbase ole32 uiautomationcore user32)

cd "$wine/dlls/winevulkan"
python3 make_vulkan -x vk.xml

cd "$wine"
tools/make_requests
tools/make_specfiles || true
autoreconf -fi

mkdir -p "$obj" "$out"
cd "$obj"

if [[ ! -f Makefile ]]; then
  "$wine/configure" --enable-win64 --with-mingw --disable-tests --without-x --without-freetype \
    CROSSCFLAGS="-g -O2 -Wno-error=incompatible-pointer-types -Wno-error=int-conversion -Wno-error=implicit-function-declaration"
fi

targets=()

for dll in "${dlls[@]}"; do
  targets+=("dlls/$dll/x86_64-windows/$dll.dll")
done

make -j"$(nproc)" "${targets[@]}"

for target in "${targets[@]}"; do
  cp "$target" "$out/"
done

echo "Built ${dlls[*]} into $out"
