#!/usr/bin/env bash
set -euo pipefail

case "${RUNNER_OS:-$(uname -s)}" in
  Linux)
    FLAGS="-lopenblas -llapack -lm"
    CFLAGS=""
    ;;
  macOS | Darwin)
    FLAGS="-framework Accelerate"
    CFLAGS=""
    ;;
  Windows | MINGW* | MSYS* | CYGWIN*)
    FLAGS="-LC:/vcpkg/installed/x64-mingw-dynamic/lib -lopenblas"
    CFLAGS="-IC:/vcpkg/installed/x64-mingw-dynamic/include -IC:/vcpkg/installed/x64-mingw-dynamic/include/openblas"
    ;;
  *)
    echo "unsupported runner OS: ${RUNNER_OS:-$(uname -s)}" >&2
    exit 1
    ;;
esac

for pkg in \
  src/nash/moon.pkg \
  src/payoff/moon.pkg \
  .mooncakes/mizchi/numbt/src/moon.pkg \
  .mooncakes/mizchi/blas/src/moon.pkg \
  .mooncakes/mizchi/blas/src/bench/moon.pkg
do
  if [ -f "$pkg" ]; then
    sed -i.bak "s|\"cc-link-flags\": \"[^\"]*\"|\"cc-link-flags\": \"$FLAGS\"|g" "$pkg"
    if [ -n "$CFLAGS" ]; then
      if grep -q '"cc-flags":' "$pkg"; then
        sed -i.bak "s|\"cc-flags\": \"[^\"]*\"|\"cc-flags\": \"$CFLAGS\"|g" "$pkg"
      else
        sed -i.bak "s|\"cc-link-flags\": \"$FLAGS\"|\"cc-link-flags\": \"$FLAGS\", \"cc-flags\": \"$CFLAGS\"|g" "$pkg"
      fi
    fi
    rm -f "$pkg.bak"
  fi
done

echo "configured native cc-link-flags: $FLAGS"
if [ -n "$CFLAGS" ]; then
  echo "configured native cc-flags: $CFLAGS"
fi
