#!/bin/sh
# Assemble the newest npm release of NPM_MAJOR into $1, then upgrade each
# bundled dependency named in NPM_DEPENDENCY_OVERRIDES to its newest release
# in the same major, or in MAJOR for a NAME@MAJOR entry (never below the
# bundled major). Dependencies an upgrade needs that the bundled tree does not
# satisfy are nested under it. Every tarball must match the registry integrity
# hash and carry a valid npm registry ECDSA signature.
set -eu

out="$1"
registry=https://registry.npmjs.org
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

curl -fsSL --retry 5 --retry-all-errors "$registry/-/npm/v1/keys" -o "$work/keys.json"

# fetch NAME MAJOR DEST: download, verify and unpack the newest NAME@MAJOR.x.y.
fetch() {
  name="$1" major="$2" dest="$3"
  curl -fsSL --retry 5 --retry-all-errors \
    -H 'Accept: application/vnd.npm.install-v1+json' \
    "$registry/$name" -o "$work/meta.json"
  version="$(jq -r --arg major "$major" '
    [.versions | keys[] | select(test("^" + $major + "\\.[0-9]+\\.[0-9]+$"))]
    | sort_by(split(".") | map(tonumber)) | last // empty' "$work/meta.json")"
  test -n "$version" || { echo "no $name@$major.x release" >&2; exit 1; }
  jq --arg v "$version" '.versions[$v]' "$work/meta.json" > "$work/manifest.json"

  curl -fsSL --retry 5 --retry-all-errors \
    "$(jq -r .dist.tarball "$work/manifest.json")" -o "$work/package.tgz"

  integrity="$(jq -r .dist.integrity "$work/manifest.json")"
  actual="sha512-$(openssl dgst -sha512 -binary "$work/package.tgz" | base64 -w0)"
  test "$actual" = "$integrity" || { echo "$name@$version: integrity mismatch" >&2; exit 1; }

  keyid="$(jq -r '.dist.signatures[0].keyid // empty' "$work/manifest.json")"
  test -n "$keyid" || { echo "$name@$version: unsigned" >&2; exit 1; }
  jq -r --arg id "$keyid" '.keys[] | select(.keyid == $id) | .key' "$work/keys.json" |
    base64 -d > "$work/key.der"
  test -s "$work/key.der" || { echo "$name@$version: unknown key $keyid" >&2; exit 1; }
  openssl pkey -pubin -inform DER -in "$work/key.der" -out "$work/key.pem"
  jq -r '.dist.signatures[0].sig' "$work/manifest.json" | base64 -d > "$work/sig.der"
  printf '%s@%s:%s' "$name" "$version" "$integrity" > "$work/message"
  openssl dgst -sha256 -verify "$work/key.pem" -signature "$work/sig.der" "$work/message" >/dev/null ||
    { echo "$name@$version: bad registry signature" >&2; exit 1; }

  rm -rf "$dest"
  mkdir -p "$dest"
  tar -xzf "$work/package.tgz" -C "$dest" --strip-components=1
  echo "$name@$version verified"
}

# satisfies RANGE VERSION: VERSION is in the caret RANGE ^X.Y.Z (X > 0).
satisfies() {
  case "$1" in
    ^[1-9]*.*.*) ;;
    *) echo "unsupported dependency range: $1" >&2; exit 1 ;;
  esac
  awk -v min="${1#^}" -v v="$2" 'BEGIN {
    split(min, a, "."); split(v, b, ".")
    if (a[1] + 0 != b[1] + 0) exit 1
    for (i = 2; i <= 3; i++) {
      if (b[i] + 0 > a[i] + 0) exit 0
      if (b[i] + 0 < a[i] + 0) exit 1
    }
  }'
}

# resolve DIR NAME: the package.json Node.js would load for NAME from DIR.
resolve() {
  dir="$1"
  while :; do
    if [ -f "$dir/node_modules/$2/package.json" ]; then
      echo "$dir/node_modules/$2/package.json"
      return
    fi
    [ "$dir" = "$out" ] && return
    dir="$(dirname "$dir")"
  done
}

# fetch_deps DIR: nest the newest matching release of each dependency of the
# package in DIR that the surrounding tree does not satisfy, recursively.
fetch_deps() {
  deps="$(mktemp "$work/deps.XXXXXX")"
  jq -r '.dependencies // {} | to_entries[] | "\(.key) \(.value)"' "$1/package.json" > "$deps"
  while read -r dep range; do
    found="$(resolve "$1" "$dep")"
    if [ -n "$found" ] && satisfies "$range" "$(jq -r .version "$found")"; then
      continue
    fi
    major="${range#^}"
    fetch "$dep" "${major%%.*}" "$1/node_modules/$dep" < /dev/null
    (fetch_deps "$1/node_modules/$dep")
  done < "$deps"
  rm -f "$deps"
}

fetch npm "$NPM_MAJOR" "$out"
for spec in $NPM_DEPENDENCY_OVERRIDES; do
  case "$spec" in
    ?*@*) name="${spec%@*}" major="${spec##*@}" ;;
    *) name="$spec" major= ;;
  esac
  bundled="$(jq -r .version "$out/node_modules/$name/package.json")"
  bundled="${bundled%%.*}"
  if [ -z "$major" ] || [ "$major" -lt "$bundled" ]; then
    major="$bundled"
  fi
  fetch "$name" "$major" "$out/node_modules/$name"
done
# Resolve dependencies only once every override is in place, so an upgraded
# package finds the other upgrades instead of nesting its own copies.
for spec in $NPM_DEPENDENCY_OVERRIDES; do
  case "$spec" in
    ?*@*) name="${spec%@*}" ;;
    *) name="$spec" ;;
  esac
  (fetch_deps "$out/node_modules/$name")
done
