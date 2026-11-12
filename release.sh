#!/bin/bash
# release: semver bump from conventional commits, changelog, build, tag, github release.
# usage: ./release.sh [version]     override the computed version
#        DRY_RUN=1 ./release.sh     print version + notes, change nothing
set -euo pipefail
cd "$(dirname "$0")"

plist() { /usr/libexec/PlistBuddy -c "$1" Info.plist; }
die() { echo "release: $*" >&2; exit 1; }

last=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)
range=${last:+$last..}HEAD
log=$(git log --no-merges --format=%s "$range")
[ -n "$log" ] || die "no commits since $last"

# version: first release takes Info.plist as is; after that feat -> minor, breaking -> major, else patch
# ponytail: breaking bumps major even on 0.x, pass a version explicitly to override
if [ -n "${1:-}" ]; then
  next=${1#v}
elif [ -z "$last" ]; then
  next=$(plist 'Print :CFBundleShortVersionString')
else
  IFS=. read -r major minor patch <<<"${last#v}"
  if echo "$log" | grep -qE '^[a-z]+(\([^)]*\))?!: ' ||
     git log --format=%b "$range" | grep -q '^BREAKING CHANGE'; then
    next=$((major + 1)).0.0
  elif echo "$log" | grep -qE '^feat(\([^)]*\))?: '; then
    next=$major.$((minor + 1)).0
  else
    next=$major.$minor.$((patch + 1))
  fi
fi
[[ $next =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "bad version: $next"

# changelog: grouped by commit type, housekeeping types hidden
section() { # title, grep flags, type regex
  local lines
  lines=$(echo "$log" | grep "$2" "^($3)(\([^)]*\))?!?: " | sed -E "s/^($3)(\([^)]*\))?!?: //; s/^/- /" || true)
  [ -z "$lines" ] || printf '### %s\n\n%s\n\n' "$1" "$lines"
}
notes=$(
  section Features -E feat
  section Fixes -E fix
  section Performance -E perf
  section Other -Ev 'feat|fix|perf|chore|docs|ci|test|build|style'
)

echo "v$next (previous: ${last:-none})"
echo
echo "$notes"
[ -z "${DRY_RUN:-}" ] || exit 0

[ -z "$(git status --porcelain)" ] || die "working tree dirty"
[ "$(git branch --show-current)" = main ] || die "not on main"

trap 'git checkout -- Info.plist' ERR
plist "Set :CFBundleShortVersionString $next"
make app
zip=.build/Nimmersatt-$next.zip
ditto -c -k --keepParent Nimmersatt.app "$zip"
trap - ERR

{
  printf '# Changelog\n\n## %s - %s\n\n%s\n' "$next" "$(date +%F)" "$notes"
  if [ -f CHANGELOG.md ]; then tail -n +2 CHANGELOG.md; fi
} > .build/CHANGELOG.md
mv .build/CHANGELOG.md CHANGELOG.md

git add Info.plist CHANGELOG.md
git commit -qm "chore: release v$next"
git tag "v$next"
git push -q origin main "v$next"
gh release create "v$next" "$zip" --title "v$next" --notes "$notes"
