#!/usr/bin/env bash
# tools/make-release.sh — build the artifacts that crypTar --update verifies.
#
#   tools/make-release.sh <tag> [gpg-key-id]
#
# Produces in dist/<tag>/:
#   cryptar-<ver>.tar.gz   — `git archive` of the tag (single top-level dir)
#   SHA256SUMS             — checksum of the archive
#   SHA256SUMS.asc         — armored detached signature (when a key is given)
# Attach all three files to the GitHub Release <tag>. See README, "Публикация релиза".
set -euo pipefail

TAG="${1:-}"
KEY="${2:-}"
[[ -n "$TAG" ]] || { echo "usage: $0 <tag> [gpg-key-id]" >&2; exit 2; }

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
source src/install/core.sh

VER="${TAG#v}"
inst_is_semver "$VER" || { echo "Тег '$TAG' не соответствует SemVer (vMAJOR.MINOR.PATCH[-N])" >&2; exit 1; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || { echo "Тег $TAG не найден" >&2; exit 1; }
TAG_VER="$(git show "$TAG:VERSION" | tr -d '\r\n')"
[[ "$TAG_VER" == "$VER" ]] || { echo "VERSION в теге ($TAG_VER) не совпадает с тегом ($VER)" >&2; exit 1; }

OUT="dist/$TAG"
mkdir -p "$OUT"
ART="cryptar-$VER.tar.gz"
git archive --format=tar --prefix="cryptar-$VER/" "$TAG" | gzip -n -9 > "$OUT/$ART"
( cd "$OUT" && sha256sum "$ART" > SHA256SUMS )

if [[ -n "$KEY" ]]; then
    gpg --armor --detach-sign --local-user "$KEY" --output "$OUT/SHA256SUMS.asc" "$OUT/SHA256SUMS"
    gpg --verify "$OUT/SHA256SUMS.asc" "$OUT/SHA256SUMS"
fi

echo "Готово: $OUT"
ls -l "$OUT"
echo "Публикация: gh release create $TAG $OUT/* --title $TAG --notes '...'"
