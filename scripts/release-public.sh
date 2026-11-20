#!/usr/bin/env bash
# Publish the CHANGELOG section of vX.Y.Z as a release on every public mirror:
# each git remote on github.com (via `gh`) or codeberg.org (via `tea --login
# codeberg`). The private forge gets its release from .forgejo/workflows/release.yml.
#
#   scripts/release-public.sh X.Y.Z
#
# The tag must already be pushed to the mirror (`just push` does that first).
# Releases that already exist are left alone, so this is safe to re-run.
set -euo pipefail

version=${1:?usage: release-public.sh X.Y.Z}
tag="v$version"

if ! grep -q "^## \[$version\]" CHANGELOG.md; then
  echo "error: CHANGELOG.md has no '## [$version]' section" >&2
  exit 1
fi

# The version's section, up to the next heading or the link references.
notes=$(mktemp)
trap 'rm -f "$notes"' EXIT
awk -v v="$version" '
  /^## \[/ { p = (index($0, "## [" v "]") == 1); next }
  /^\[[^]]+\]: / { p = 0 }
  p
' CHANGELOG.md >"$notes"
prev=$(git tag --list 'v*' | sort -V | grep -B1 -x "$tag" | head -1 || true)

# host and owner/repo of a remote URL (scp-style, ssh:// or https://).
parse() {
  sed -E -e 's#^(ssh|https?)://##' -e 's#^[^@/]+@##' -e 's#\.git$##' -e 's#[:/]# #' <<<"$1"
}

published=0
for remote in $(git remote); do
  read -r host slug <<<"$(parse "$(git remote get-url "$remote")")"
  case "$host" in
  github.com | codeberg.org) published=$((published + 1)) ;;
  *) continue ;;
  esac
  body=$(cat "$notes")
  if [ -n "$prev" ] && [ "$prev" != "$tag" ]; then
    body+=$'\n\n'"**Full changelog:** https://$host/$slug/compare/$prev...$tag"
  fi

  case "$host" in
  github.com)
    if gh release view "$tag" --repo "$slug" >/dev/null 2>&1; then
      echo "$remote: $tag already released on $host/$slug"
    else
      gh release create "$tag" --repo "$slug" --verify-tag --title "$tag" --notes "$body"
      echo "$remote: released $tag on https://$host/$slug/releases/tag/$tag"
    fi
    ;;
  codeberg.org)
    if ! tea logins list --output simple 2>/dev/null | awk '{print $1}' | grep -qx codeberg; then
      echo "$remote: skipped, no tea login named 'codeberg'." >&2
      echo "  tea login add --name codeberg --url https://codeberg.org --token <token>" >&2
      continue
    fi
    if tea releases list --login codeberg --repo "$slug" --output simple 2>/dev/null | awk '{print $1}' | grep -qx "$tag"; then
      echo "$remote: $tag already released on $host/$slug"
    else
      tea releases create --login codeberg --repo "$slug" --tag "$tag" --title "$tag" --note "$body"
      echo "$remote: released $tag on https://$host/$slug/releases/tag/$tag"
    fi
    ;;
  esac
done

[ "$published" -gt 0 ] || echo "No GitHub or Codeberg remote: nothing to publish."
