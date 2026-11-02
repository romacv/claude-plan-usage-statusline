#!/usr/bin/env bash
# Usage: release.sh vX.Y.Z -m "commit message" [--dry-run]
# Syncs installed statusline.rb and refresh-usage-cache.sh into the repo, commits, pushes main, creates the GitHub release.
set -euo pipefail
cd "$(dirname "$0")"

ver= msg= dry=0
while [ $# -gt 0 ]; do
  case $1 in
    -m) msg=${2:?-m needs a message}; shift 2 ;;
    --dry-run) dry=1; shift ;;
    v*) ver=$1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ $ver =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must be vX.Y.Z" >&2; exit 2; }
[ -n "$msg" ] || { echo "-m message required" >&2; exit 2; }

files="statusline.rb refresh-usage-cache.sh"
src() { case $1 in statusline.rb) echo "$HOME/.claude/statusline.rb" ;; *) echo "$HOME/.claude/$1" ;; esac; }
die() { echo "refused: $*" >&2; exit 1; }
run() { echo "+ $*"; [ $dry -eq 1 ] || "$@"; }

[ "$(git branch --show-current)" = main ] || die "not on main"
other=$(git status --porcelain | grep -Ev ' (README.md|release.sh)$' || true)
[ -z "$other" ] || die "unrelated changes in working tree:
$other"

git fetch -q --tags origin
prev=$(git tag --sort=-v:refname | head -1)
[ "$(printf '%s\n%s\n' "$prev" "$ver" | sort -V | tail -1)" = "$ver" ] && [ "$prev" != "$ver" ] || die "$ver is not greater than $prev"

changed=
for f in $files; do
  [ -f "$(src $f)" ] || die "missing installed $(src $f)"
  cmp -s "$(src $f)" "$f" || changed="$changed $f"
done
ruby -c "$(src statusline.rb)" >/dev/null || die "ruby syntax check failed"
readme_dirty=$(git status --porcelain README.md)
[ -n "$changed" ] || [ -n "$readme_dirty" ] || die "nothing to release: installed copies match the repo"

rb_changed=$(git diff --name-only "$prev" -- statusline.rb)
case "$changed" in *statusline.rb*) rb_changed=statusline.rb ;; esac
if [ -n "$rb_changed" ] && git diff --quiet "$prev" -- README.md; then
  die "statusline.rb changed since $prev but README.md was not touched; update README first"
fi

echo "release $ver (previous $prev), changed:${changed:- none}"
for f in $changed; do run cp "$(src $f)" "$f"; done
run git add $files README.md
run git commit -m "$msg"
run git push origin main
run git fetch origin
if [ $dry -eq 1 ]; then
  echo "+ check: git rev-list --left-right --count origin/main...HEAD == '0	0'"
else
  [ "$(git rev-list --left-right --count origin/main...HEAD)" = "0	0" ] || die "origin/main and HEAD differ after push"
fi

if [ $dry -eq 1 ]; then
  notes=$( { echo "- $msg"; git log --format='- %s' "$prev..HEAD"; } )
else
  notes=$(git log --format='- %s' "$prev..HEAD")
fi
echo "notes:"; echo "$notes"
run gh release create "$ver" --target main --title "$ver" --notes "$notes"

echo "+ verify installed copies are byte-identical to the repo"
if [ $dry -eq 0 ]; then
  for f in $files; do cmp "$(src $f)" "$f" || die "$f differs from installed copy"; done
fi
echo done
