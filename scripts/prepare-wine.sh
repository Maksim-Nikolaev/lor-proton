#!/usr/bin/env bash
set -euo pipefail

ge_tag="${GE_TAG:-GE-Proton9-27}"
src="/build/src"
ge="$src/proton-ge-custom"

if [[ ! -d "$ge/.git" ]]; then
  git clone --branch "$ge_tag" --depth 1 https://github.com/GloriousEggroll/proton-ge-custom "$ge"
fi

cd "$ge"
git submodule update --init --filter=blob:none wine wine-staging

sed -n '/^### (2) WINE PATCHING ###/,$p' patches/protonprep-valve-staging.sh > /tmp/protonprep-wine.sh
bash /tmp/protonprep-wine.sh

cd wine

for patch_file in /repo/patches/*.patch; do
  echo "Applying $(basename "$patch_file")"
  patch -Np1 --no-backup-if-mismatch < "$patch_file"
done

cd "$ge"

echo "Prepared $ge/wine at $(git -C wine rev-parse --short HEAD) with GE-Proton patches from $ge_tag"
