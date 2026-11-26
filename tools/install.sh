#!/bin/bash
# Install the latest CI build of zzz.notch into /Applications.
#
# CI artifacts are ad-hoc signed, so their code identity is a per-build hash and
# macOS drops Accessibility and other privacy grants on every update. This
# re-signs the bundle with a local code-signing identity so grants persist
# across builds.
#
#   tools/install.sh [RUN_ID]
#   ZZZ_SIGN_IDENTITY="name or SHA-1"  (default: first valid codesigning identity)
set -euo pipefail

repo=$(git -C "$(dirname "$0")" remote get-url origin | sed -E 's#^(git@github.com:|https://github.com/)##; s#\.git$##')
dest=/Applications/zzz.notch.app

identity=${ZZZ_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk 'NR==1 && $2 ~ /^[0-9A-F]{40}$/ {print $2}')}
[ -n "$identity" ] || { echo "no code-signing identity; set ZZZ_SIGN_IDENTITY" >&2; exit 1; }

if [ -n "${1:-}" ]; then
  run=$1
else
  latest_json=$(gh run list -R "$repo" --branch main --workflow "Build for macOS" -L 1 --json databaseId,status,conclusion,headSha --jq '.[0]')
  run=$(printf '%s' "$latest_json" | jq -r '.databaseId // empty')
  status=$(printf '%s' "$latest_json" | jq -r '.status // empty')
  conclusion=$(printf '%s' "$latest_json" | jq -r '.conclusion // empty')
  sha=$(printf '%s' "$latest_json" | jq -r '.headSha // empty' | cut -c1-7)
  [ -n "$run" ] || { echo "no CI runs found on main" >&2; exit 1; }
  if [ "$status" != "completed" ]; then
    echo "waiting for CI run $run ($sha, status=$status) to finish..."
    gh run watch "$run" -R "$repo" --exit-status
  elif [ "$conclusion" != "success" ]; then
    echo "latest CI run $run ($sha) on main ended with '$conclusion'; refusing to install a stale build" >&2
    exit 1
  fi
fi
artifact=$(gh api "repos/$repo/actions/runs/$run/artifacts" --jq '.artifacts[] | select(.name | startswith("zzz-notch")) | .name')
[ -n "$artifact" ] || { echo "run $run has no zzz-notch artifact" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
gh run download "$run" -R "$repo" -n "$artifact" -D "$work"
ditto -x -k "$work/zzz-notch.zip" "$work"
app=$(find "$work" -maxdepth 1 -name '*.app' | head -1)

# Inside-out, keeping each bundle's entitlements. No hardened runtime: the
# vendored MediaRemoteAdapter would fail library validation under it.
sign() { codesign --force --sign "$identity" --preserve-metadata=entitlements "$1"; }
sign "$app/Contents/Frameworks/MediaRemoteAdapter.framework"
for xpc in "$app"/Contents/XPCServices/*.xpc; do sign "$xpc"; done
sign "$app"
codesign --verify --deep --strict "$app"

osascript -e "quit app \"$dest\"" 2>/dev/null || true
sleep 1
pkill -f "$dest/Contents/" 2>/dev/null || true
rm -rf "$dest"
ditto "$app" "$dest"
xattr -cr "$dest"
open "$dest"
echo "installed run $run ($artifact) signed by $identity"
