#!/usr/bin/env bash
# Builds the Flutter Linux release bundle and packages it as an RPM
# (packaging/$NAME.spec). Runs in a Fedora container (.forgejo/workflows/rpm.yml)
# with this repo at /src, a cache that outlives the job at /cache (the
# Flutter SDK and pub packages), and the RPMs going to /out.
#
#   podman run --rm -v "$PWD":/src -v /var/cache/quine-rpm-build:/cache \
#     -v "$PWD/out":/out registry.fedoraproject.org/fedora:44 \
#     bash /src/packaging/build-flutter-rpm.sh layer-wizard
set -euo pipefail
NAME=$1

# Flutter's stable release, pinned (storage.googleapis.com/flutter_infra_release/releases/releases_linux.json).
FLUTTER_VERSION=3.47.9
FLUTTER_SHA256=25ed8c3c29d51a7353f2a944310b478af8214920639524b19c50a19e6c044c5a

dnf install -y --setopt=install_weak_deps=False \
  clang cmake ninja-build pkgconf-pkg-config gtk3-devel xz-devel libstdc++-devel \
  git xz which unzip rpm-build desktop-file-utils

sdk=/cache/flutter-$FLUTTER_VERSION
if [ ! -x "$sdk/bin/flutter" ]; then
  curl -fL --retry 3 -o /cache/flutter.tar.xz \
    "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_$FLUTTER_VERSION-stable.tar.xz"
  echo "$FLUTTER_SHA256  /cache/flutter.tar.xz" | sha256sum -c
  rm -rf "$sdk.tmp" && mkdir -p "$sdk.tmp"
  tar -xJf /cache/flutter.tar.xz -C "$sdk.tmp" --strip-components=1
  mv "$sdk.tmp" "$sdk" && rm /cache/flutter.tar.xz
fi
# The SDK and this checkout belong to other users than the container's root.
git config --global --add safe.directory '*'
export PUB_CACHE=/cache/pub PATH="$sdk/bin:$PATH"
flutter --disable-analytics >/dev/null 2>&1 || true

cd /src
flutter build linux --release

version=$(sed -n 's/^version: *\([0-9][0-9.]*\).*/\1/p' pubspec.yaml)
release=$(date -u +%Y%m%d%H%M).git$(git rev-parse --short=7 HEAD)
rpmbuild -bb "packaging/$NAME.spec" \
  --define "_topdir /tmp/rpmbuild" \
  --define "version_ $version" --define "release_ $release" \
  --define "bundle /src/build/linux/x64/release/bundle" --define "srcdir /src"
cp -v /tmp/rpmbuild/RPMS/*/*.rpm /out/
