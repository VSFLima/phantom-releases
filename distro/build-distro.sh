#!/usr/bin/env bash
set -euo pipefail

# Rebuilds phantom.tar.gz for the Android app:
#   - keeps rootfs.img, kernel, initrd.img and ROMs from the previous release tarball
#   - replaces qemu-system-aarch64 with the Termux (bionic) QEMU build
#   - bundles all dynamically-linked libraries next to the binary
# This runs entirely on GitHub Actions.

REPO="${1:?usage: build-distro.sh <repo>}"
RELEASE_TAG="${2:-distro-phantom}"

ROOT="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

STAGING="$WORK/staging"
DEBS="$WORK/debs"
mkdir -p "$STAGING/lib" "$DEBS"

SYSTEM="libc.so libm.so libdl.so libandroid.so liblog.so libstdc++.so libc++.so"

# Termux official repo plus mirrors to fall back on if a download looks wrong
MIRRORS=(
  "https://packages.termux.dev/apt/termux-main"
  "https://grimler.se/termux/apt/termux-main"
)

echo ">> Downloading previous distro release (base content)"
BASE_URL="https://github.com/$REPO/releases/download/$RELEASE_TAG/phantom.tar.gz"
curl -fsSL --retry 3 "$BASE_URL" -o "$WORK/base.tar.gz"

echo ">> Extracting base content"
tar -xzf "$WORK/base.tar.gz" -C "$STAGING"
rm -f "$STAGING/qemu-system-aarch64"
rm -rf "$STAGING/lib"
mkdir -p "$STAGING/lib"

download_deb() {
  local rel="$1" out="$2"
  for base in "${MIRRORS[@]}"; do
    curl -fsSL --retry 4 --retry-all-errors -A "Termux/0.118.0" "$base/$rel" -o "$out" && \
      [ -s "$out" ] && [ "$(head -c 8 "$out" | tr -d '\0')" = "!<arch>" ] && return 0
  done
  return 1
}

echo ">> Downloading Termux QEMU + libraries ($(wc -l < "$ROOT/debs.txt") packages)"
while IFS=$'\t' read -r url sha; do
  name="$(basename "$url")"
  rel="${url#https://packages.termux.dev/apt/termux-main/}"
  if ! download_deb "$rel" "$DEBS/$name"; then
    echo "DOWNLOAD FAILED for $name"
    exit 1
  fi
  if [ "$(sha256sum "$DEBS/$name" | cut -d' ' -f1)" != "$sha" ]; then
    echo "SHA-256 mismatch for $name (got $(sha256sum "$DEBS/$name" | cut -d' ' -f1))"
    exit 1
  fi
done < "$ROOT/debs.txt"

echo ">> Extracting packages"
: > "$WORK/libfiles"
for deb in "$DEBS"/*.deb; do
  d="$WORK/x-$(basename "$deb" .deb)"
  mkdir -p "$d"
  (cd "$d" && ar x "$deb")
  tar -xf "$d"/data.tar.* -C "$d" 2>/dev/null
  find "$d" -type f -name '*.so*' -print >> "$WORK/libfiles" 2>/dev/null || true
done

echo ">> Locating QEMU binary"
QEMU_BIN="$(find "$WORK" -path '*/usr/bin/qemu-system-aarch64' -type f | head -1)"
[ -n "$QEMU_BIN" ] || { echo "qemu-system-aarch64 not found"; exit 1; }
cp "$QEMU_BIN" "$STAGING/qemu-system-aarch64"

echo ">> Installing QEMU firmware (qemu-common)"
FW_DIR="$(find "$WORK" -path '*/usr/share/qemu' -type d | head -1)"
[ -n "$FW_DIR" ] || { echo "qemu firmware directory not found"; exit 1; }
cp -rf "$FW_DIR/." "$STAGING/"

echo ">> Mapping SONAMEs -> files"
declare -A soname_file
while IFS= read -r f; do
  soname="$(readelf -d "$f" 2>/dev/null | sed -n 's/.*Library soname: \[\([^]]*\)\].*/\1/p' | head -1)" || true
  if [ -n "$soname" ]; then
    [ -n "${soname_file[$soname]:-}" ] || soname_file["$soname"]="$f"
  else
    [ -n "${soname_file[$(basename "$f")]:-}" ] || soname_file["$(basename "$f")"]="$f"
  fi
done < <(grep -v '^$' "$WORK/libfiles")

echo ">> Copying required libraries"
missing=0
while IFS= read -r soname; do
  [ -n "$soname" ] || continue
  if [ -n "${soname_file[$soname]:-}" ]; then
    cp "${soname_file[$soname]}" "$STAGING/lib/$soname"
  else
    echo "MISSING lib: $soname"
    missing=1
  fi
done < "$ROOT/sonames.txt"
[ "$missing" -eq 0 ] || { echo "One or more required libraries were not found"; exit 1; }

echo ">> Verifying the dynamic dependency closure"
for f in "$STAGING/qemu-system-aarch64" "$STAGING"/lib/*; do
  for dep in $(readelf -d "$f" 2>/dev/null | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p' | sort -u); do
    if [ ! -f "$STAGING/lib/$dep" ] && ! echo "$SYSTEM" | grep -q -w "$dep"; then
      echo "UNRESOLVED dependency: $f -> $dep"
      exit 1
    fi
  done
done

echo ">> Repackaging phantom.tar.gz"
chmod 0755 "$STAGING/qemu-system-aarch64" "$STAGING"/lib/*
printf '%s\n' "${DISTRO_VERSION:-3}" > "$STAGING/VERSION"
FILES=()
for entry in "$STAGING"/*; do FILES+=("$(basename "$entry")"); done
(cd "$STAGING" && tar --format=ustar -czf "$WORK/phantom.tar.gz" "${FILES[@]}")

sha256sum "$WORK/phantom.tar.gz" | awk '{print $1}' > "$WORK/phantom.sha256"
echo "phantom.tar.gz sha256: $(cat "$WORK/phantom.sha256")"
ls -lh "$WORK/phantom.tar.gz"

echo ">> Uploading assets to $REPO ($RELEASE_TAG)"
gh release upload "$RELEASE_TAG" "$WORK/phantom.sha256" --repo "$REPO" --clobber
gh release upload "$RELEASE_TAG" "$WORK/phantom.tar.gz" --repo "$REPO" --clobber
echo ">> Done"
