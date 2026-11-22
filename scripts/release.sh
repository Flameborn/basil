#!/bin/sh
# Makes a Basil release: sets the version, moves the changelog's "Unreleased" entries
# under the new version, builds the DMG, commits, tags, pushes and publishes a GitHub
# release with the DMG and those entries as notes.
#
#   scripts/release.sh            release the version in project.yml (only while it has no tag yet;
#                                 this is how the first release, 0.1.0, is made)
#   scripts/release.sh patch      0.1.0 -> 0.1.1
#   scripts/release.sh minor      0.1.0 -> 0.2.0
#   scripts/release.sh major      0.1.0 -> 1.0.0
#   scripts/release.sh 0.3.0      an exact version (must be higher than the current one)
#   add --dry-run                 build the DMG and show the notes, then put the files back;
#                                 nothing is committed, tagged, pushed or published
#
# The version lives in project.yml (CFBundleShortVersionString). The build number
# (CFBundleVersion) goes up by one with every version change. Tags are v<version>.
# Needs: a clean work tree on master, in step with origin, and gh logged in.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

changelog="docs/changelog.md"
bump=""
dry=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) dry=1 ;;
        -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) [ -z "$bump" ] || { echo "error: more than one version given" >&2; exit 1; }; bump="$arg" ;;
    esac
done

fail() { echo "error: $*" >&2; exit 1; }

# --- checks ---------------------------------------------------------------------------
[ -z "$(git status --porcelain)" ] || fail "the work tree has changes; commit or stash them first"
branch="$(git rev-parse --abbrev-ref HEAD)"
[ "$branch" = "master" ] || fail "releases are made from master (on $branch)"
if [ "$dry" -eq 0 ]; then
    gh auth status >/dev/null 2>&1 || fail "gh is not logged in (run: gh auth login)"
    git fetch --quiet origin master
    [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/master)" ] \
        || fail "master and origin/master differ; pull or push first"
fi
[ -f "$changelog" ] || fail "$changelog is missing"

# --- version --------------------------------------------------------------------------
current="$(sed -nE 's/^ *CFBundleShortVersionString: *"([^"]+)".*/\1/p' project.yml)"
build="$(sed -nE 's/^ *CFBundleVersion: *"([^"]+)".*/\1/p' project.yml)"
echo "$current" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || fail "project.yml version '$current' is not x.y.z"

major="${current%%.*}"; rest="${current#*.}"; minor="${rest%%.*}"; patch="${rest#*.}"
case "$bump" in
    "")    git rev-parse -q --verify "refs/tags/v$current" >/dev/null \
               && fail "v$current is already released; pass patch, minor, major or a version"
           version="$current" ;;
    patch) version="$major.$minor.$((patch + 1))" ;;
    minor) version="$major.$((minor + 1)).0" ;;
    major) version="$((major + 1)).0.0" ;;
    *)     echo "$bump" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || fail "unknown argument '$bump'"
           higher="$(printf '%s\n%s\n' "$current" "$bump" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
           [ "$bump" != "$current" ] && [ "$higher" = "$bump" ] || fail "$bump is not higher than $current"
           version="$bump" ;;
esac
git rev-parse -q --verify "refs/tags/v$version" >/dev/null && fail "tag v$version already exists"
[ "$version" = "$current" ] || build=$((build + 1))

# --- release notes from the changelog -------------------------------------------------
grep -q '^## Unreleased *$' "$changelog" || fail "$changelog has no '## Unreleased' section"
notes="$(mktemp "${TMPDIR:-/tmp}/basil-notes.XXXXXX")"
awk '/^## Unreleased *$/ { on = 1; next } on && /^## / { exit } on { print }' "$changelog" \
    | sed -e '/./,$!d' | awk '{ lines[NR] = $0 } END { n = NR; while (n > 0 && lines[n] ~ /^[[:space:]]*$/) n--; for (i = 1; i <= n; i++) print lines[i] }' \
    >"$notes"
[ -s "$notes" ] || fail "the Unreleased section of $changelog is empty; write what changed first"

echo "Releasing Basil $version (build $build), current $current"
echo "--- notes ---"; cat "$notes"; echo "-------------"

# --- edit the files (put back on any failure before the commit) -------------------------
committed=0
restore() {
    rm -f "$notes"
    if [ "$committed" -eq 0 ]; then git checkout --quiet -- project.yml "$changelog"; fi
}
trap restore EXIT

today="$(date +%Y-%m-%d)"
sed -i '' -E \
    -e "s/^( *CFBundleShortVersionString: *)\"[^\"]+\"/\1\"$version\"/" \
    -e "s/^( *CFBundleVersion: *)\"[^\"]+\"/\1\"$build\"/" project.yml
awk -v heading="## $version - $today" '
    !done && /^## Unreleased *$/ { print; print ""; print heading; done = 1; next }
    { print }' "$changelog" >"$changelog.new" && mv "$changelog.new" "$changelog"

scripts/build-dmg.sh
dmg="build/dist/Basil-$version.dmg"

if [ "$dry" -eq 1 ]; then
    echo "Dry run: $dmg built; project.yml and $changelog put back, nothing committed or published"
    exit 0
fi

# --- commit, tag, push, publish ---------------------------------------------------------
git add project.yml "$changelog"
git commit --quiet -m "Release $version"
committed=1
git tag -a "v$version" -m "Basil $version"
git push --quiet origin master "v$version"
gh release create "v$version" "$dmg" --title "Basil $version" --notes-file "$notes" --verify-tag
echo "Released Basil $version: $(gh release view "v$version" --json url -q .url)"
