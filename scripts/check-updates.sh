#!/usr/bin/env bash
# Compare versions.env with the latest stable upstream releases.
#
#   scripts/check-updates.sh                   list available updates
#   scripts/check-updates.sh --json            same, as a JSON array (for CI matrices)
#   scripts/check-updates.sh --apply <comp>    pin <comp> to its latest release in
#                                              versions.env and the README
#
# "Latest stable" means: the highest release tag for QEMU, virglrenderer and
# libepoxy (no release candidates), and for ANGLE the head of the chromium/<build>
# branch that the current Chrome stable for Mac ships.
#
# Runs on macOS and Linux; needs git, curl and python3.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

CHROMIUMDASH="https://chromiumdash.appspot.com/fetch_releases?channel=Stable&platform=Mac&num=1"

# Highest tag of <url> matching the extended regex <pattern>.
latest_tag() {
    git ls-remote --tags --refs "$1" |
        sed 's#.*refs/tags/##' |
        grep -E "$2" |
        sort -V |
        tail -1
}

# Prints "<new ref>" for a tag-based component.
latest_qemu()          { latest_tag "$QEMU_URL" '^v[0-9]+\.[0-9]+\.[0-9]+$'; }
latest_virglrenderer() { latest_tag "$VIRGLRENDERER_URL" '^virglrenderer-[0-9]+\.[0-9]+\.[0-9]+$'; }
latest_libepoxy()      { latest_tag "$LIBEPOXY_URL" '^[0-9]+\.[0-9]+\.[0-9]+$'; }

# Prints "<chrome version> <branch> <commit>" for ANGLE.
latest_angle() {
    local chrome build branch sha
    chrome="$(curl -fsSL "$CHROMIUMDASH" | python3 -c 'import json, sys; print(json.load(sys.stdin)[0]["version"])')"
    build="$(echo "$chrome" | cut -d. -f3)"
    branch="chromium/$build"
    sha="$(git ls-remote "$ANGLE_URL" "refs/heads/$branch" | cut -f1)"
    [ -n "$sha" ] || die "angle: branch $branch not found"
    echo "$chrome $branch $sha"
}

# Human-readable version of a component, as used in branch names and titles.
#   describe <component> <ref> [chrome version]
describe() {
    case "$1" in
        angle) echo "chrome-$3-${2:0:10}" ;;
        *) echo "$2" ;;
    esac
}

# Prints one line per outdated component: <component> <current> <latest>
list_updates() {
    local c cur new chrome branch sha
    for c in "${COMPONENTS[@]}"; do
        if [ "$c" = angle ]; then
            read -r chrome branch sha <<<"$(latest_angle)"
            [ "$sha" = "$ANGLE_REF" ] && continue
            echo "angle $(describe angle "$ANGLE_REF" "$ANGLE_CHROME_VERSION") $(describe angle "$sha" "$chrome")"
        else
            cur="$(component_ref "$c")"
            new="$("latest_$c")"
            [ -n "$new" ] || die "$c: no release tags found"
            [ "$new" = "$cur" ] && continue
            # Never downgrade, e.g. if a tag disappears upstream.
            [ "$(printf '%s\n%s\n' "$cur" "$new" | sort -V | tail -1)" = "$new" ] || continue
            echo "$c $cur $new"
        fi
    done
}

# set_var <name> <value>: rewrite NAME=... in versions.env
set_var() {
    NAME="$1" VALUE="$2" perl -pi -e 's/^\Q$ENV{NAME}\E=.*/$ENV{NAME}=$ENV{VALUE}/' "$ROOT/versions.env"
    grep -q "^$1=$2\$" "$ROOT/versions.env" || die "failed to set $1 in versions.env"
}

# Regenerate the README's version table from versions.env.
render_readme_versions() {
    # shellcheck source=../versions.env
    source "$ROOT/versions.env"
    local milestone="${ANGLE_CHROME_VERSION%%.*}" table
    table="$(cat <<EOF
| Component | Version |
|---|---|
| [QEMU](https://www.qemu.org) | ${QEMU_REF#v} (\`qemu-system-aarch64\`, \`qemu-system-x86_64\`, \`qemu-img\`) |
| [virglrenderer](https://gitlab.freedesktop.org/virgl/virglrenderer) | ${VIRGLRENDERER_REF#virglrenderer-} |
| [libepoxy](https://github.com/anholt/libepoxy) | ${LIBEPOXY_REF} |
| [ANGLE](https://chromium.googlesource.com/angle/angle) | Chrome $milestone stable branch (\`$ANGLE_BRANCH\`), Metal backend only |
EOF
)"
    TABLE="$table" perl -0pi -e \
        's/(<!-- versions:start -->\n).*?(\n<!-- versions:end -->)/$1$ENV{TABLE}$2/s' "$ROOT/README.md"
}

apply_update() {
    local c="$1" new chrome branch sha
    case "$c" in
        angle)
            read -r chrome branch sha <<<"$(latest_angle)"
            set_var ANGLE_CHROME_VERSION "$chrome"
            set_var ANGLE_BRANCH "$branch"
            set_var ANGLE_REF "$sha"
            ;;
        qemu | virglrenderer | libepoxy)
            new="$("latest_$c")"
            set_var "$(var_prefix "$c")_REF" "$new"
            ;;
        *) die "unknown component: $c" ;;
    esac
    render_readme_versions
}

case "${1:-}" in
    "")
        updates="$(list_updates)"
        if [ -z "$updates" ]; then
            log "everything is up to date"
        else
            printf '%-14s %-32s -> %s\n' $updates
        fi
        ;;
    --json)
        list_updates | python3 -c '
import json, sys
updates = []
for line in sys.stdin:
    component, current, latest = line.split()
    updates.append({
        "component": component,
        "current": current,
        "latest": latest,
        "branch": f"update/{component}-{latest}",
    })
print(json.dumps(updates))'
        ;;
    --apply)
        [ $# -eq 2 ] || die "usage: $0 --apply <component>"
        apply_update "$2"
        ;;
    --render-readme)
        render_readme_versions
        ;;
    *)
        die "usage: $0 [--json | --apply <component> | --render-readme]"
        ;;
esac
