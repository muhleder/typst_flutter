#!/bin/sh
# Fails when any object in an Apple static library was compiled for a newer
# deployment target than the one consumers link against.
#
# Objects compiled by rustc are stamped with the target's default minimum, but
# objects produced by build scripts (aws-lc's perlasm output, CMake builds,
# flutter_rust_bridge's `cc` shim) inherit the SDK default of whatever machine
# built them. Without an explicit deployment target the release archive then
# carries, say, minos 26.5 while an app links at 12.0, and every developer sees
# "was built for newer 'macOS' version ... than being linked" once per object.
#
# Usage: check_deployment_stamps.sh <library.a> <macos|ios> <floor>

set -eu

archive=${1:?usage: $0 <library.a> <macos|ios> <floor>}
platform=${2:?usage: $0 <library.a> <macos|ios> <floor>}
floor=${3:?usage: $0 <library.a> <macos|ios> <floor>}

case "$platform" in
  macos) want=MACOS ;;
  ios) want=IOS ;;
  *)
    echo "check_deployment_stamps: unknown platform '$platform'" >&2
    exit 2
    ;;
esac

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# A fat archive cannot be extracted directly; thin it per arch first. Device
# slices ship as thin archives, so handle both shapes.
if lipo -info "$archive" | grep -q 'Architectures in the fat file'; then
  i=0
  for arch in $(lipo -archs "$archive"); do
    i=$((i + 1))
    lipo -thin "$arch" "$archive" -output "$tmp/slice-$i.a"
    mkdir "$tmp/slice-$i"
    (cd "$tmp/slice-$i" && ar -x "$tmp/slice-$i.a")
  done
else
  mkdir "$tmp/slice-1"
  cp "$archive" "$tmp/slice-1.a"
  (cd "$tmp/slice-1" && ar -x "$tmp/slice-1.a")
fi

checked=0
offenders=0

for object in "$tmp"/slice-*/*.o; do
  [ -f "$object" ] || continue
  build_version=$(vtool -show-build-version "$object" 2>/dev/null || true)
  object_platform=$(printf '%s\n' "$build_version" | sed -n 's/^ *platform //p')
  # Modern objects carry LC_BUILD_VERSION (`minos`); older ones carry
  # LC_VERSION_MIN_* which vtool prints as a bare `version`.
  object_minos=$(printf '%s\n' "$build_version" | sed -n 's/^ *minos //p')
  [ -n "$object_minos" ] ||
    object_minos=$(printf '%s\n' "$build_version" | sed -n 's/^ *version //p')

  # Object files without a build version (pure assembly without a load command,
  # bitcode stubs) carry no floor and cannot trigger the linker warning.
  [ -n "$object_minos" ] || continue

  # LC_VERSION_MIN_* load commands print no `platform` line; the archive is
  # already per-platform, so only filter when the object states one.
  if [ -n "$object_platform" ]; then
    case "$object_platform" in
      "$want"*) ;;
      *) continue ;;
    esac
  fi

  checked=$((checked + 1))

  newer=$(awk -v object_minos="$object_minos" -v floor="$floor" '
    function compare(a, b,   an, bn, i, av, bv) {
      an = split(a, x, ".")
      bn = split(b, y, ".")
      for (i = 1; i <= 3; i++) {
        av = (i <= an) ? x[i] + 0 : 0
        bv = (i <= bn) ? y[i] + 0 : 0
        if (av > bv) return 1
        if (av < bv) return -1
      }
      return 0
    }
    BEGIN {
      result = compare(object_minos, floor)
      print (result > 0 ? "yes" : "no")
    }
  ')

  if [ "$newer" = "yes" ]; then
    offenders=$((offenders + 1))
    echo "  ${object_minos}  ${object##*/}"
  fi
done

if [ "$checked" -eq 0 ]; then
  echo "check_deployment_stamps: no ${platform} objects found in $archive" >&2
  exit 1
fi

if [ "$offenders" -ne 0 ]; then
  echo "check_deployment_stamps: $offenders of $checked ${platform} objects" \
    "were built for a newer target than ${floor}." >&2
  echo "Set the deployment target in the build that produced them" \
    "(see release.yml and the justfile)." >&2
  exit 1
fi

echo "check_deployment_stamps: $checked ${platform} objects, all at or below" \
  "${floor}."
