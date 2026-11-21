#!/usr/bin/env bash
# Usage: scripts/release.sh <version> [tap-checkout-dir]
#
# Tags v<version>, pushes the tag, downloads the tag tarball, and rewrites `url` and
# `sha256` in the tap's Formula/agent-lock.rb. Does not push the tap: it prints the
# remaining steps instead.
set -euo pipefail

version="${1:?usage: scripts/release.sh <version> [tap-checkout-dir]}"
version="${version#v}"
tag="v$version"
root="$(cd "$(dirname "$0")/.." && pwd)"
tap="${2:-${AGENT_LOCK_TAP_DIR:-$root/../homebrew-tap}}"
formula="$tap/Formula/agent-lock.rb"

cd "$root"
[[ -f "$formula" ]] || { echo "error: $formula not found (pass the tap checkout as the 2nd argument)" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "error: working tree is not clean" >&2; exit 1; }

code_version="$(sed -nE 's/.*static let version = "([^"]+)".*/\1/p' Sources/AgentLockCore/Config.swift)"
[[ "$code_version" == "$version" ]] || {
  echo "error: AgentLock.version is \"$code_version\"; bump it to \"$version\" and commit first" >&2
  exit 1
}

remote_url="$(git remote get-url origin)"
slug="$(sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##' <<<"$remote_url")"
url="https://github.com/$slug/archive/refs/tags/$tag.tar.gz"

git tag -a "$tag" -m "agent-lock $version"
git push origin "$tag"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
for attempt in 1 2 3 4 5; do
  curl -fsSL -o "$tmp/src.tar.gz" "$url" && break
  echo "tarball not available yet, retrying ($attempt)..." >&2
  sleep 3
done
[[ -s "$tmp/src.tar.gz" ]] || { echo "error: could not download $url" >&2; exit 1; }
sha="$(shasum -a 256 "$tmp/src.tar.gz" | cut -d' ' -f1)"

sed -i '' -E \
  -e "s#^  url \".*\"#  url \"$url\"#" \
  -e "s#^  sha256 \".*\"#  sha256 \"$sha\"#" \
  -e "s#^  homepage \".*\"#  homepage \"https://github.com/$slug\"#" \
  "$formula"

cat <<MSG
Updated $formula
  url    $url
  sha256 $sha

Next steps:
  cd "$tap"
  git diff
  brew install --build-from-source ./Formula/agent-lock.rb && brew test agent-lock
  git commit -am "agent-lock $version" && git push
MSG
