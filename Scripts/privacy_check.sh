#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

failed=0

reject_literal() {
    local label="$1"
    local literal="$2"
    [[ -n "$literal" ]] || return 0
    if git grep -n -F -- "$literal" -- ':!Scripts/privacy_check.sh' >/dev/null 2>&1; then
        echo "Privacy check failed: tracked files contain $label." >&2
        failed=1
    fi
}

reject_pattern() {
    local label="$1"
    local pattern="$2"
    if git grep -n -E -- "$pattern" -- ':!Scripts/privacy_check.sh' >/dev/null 2>&1; then
        echo "Privacy check failed: tracked files contain $label." >&2
        failed=1
    fi
}

reject_literal "the release Mac home path" "${HOME:-}"
reject_literal "the global Git author name" "$(git config --global user.name 2>/dev/null || true)"
reject_literal "the global Git author email" "$(git config --global user.email 2>/dev/null || true)"

reject_pattern "an absolute macOS user-home path" '/Users/[^/[:space:]]+'
reject_pattern "a private key block" 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY'
reject_pattern "an Apple app-specific password" '(^|[^A-Za-z0-9])xxxx-[a-z]{4}-[a-z]{4}-[a-z]{4}([^A-Za-z0-9]|$)'
reject_pattern "an OpenAI-style secret" '(^|[^A-Za-z0-9])sk-[A-Za-z0-9_-]{20,}'

if git grep -n -E -- '(^|[^A-Z0-9])AKIA[0-9A-Z]{16}([^A-Z0-9]|$)' \
    | grep -vF 'AKIAIOSFODNN7EXAMPLE' >/dev/null 2>&1; then
    echo "Privacy check failed: tracked files contain an AWS access key." >&2
    failed=1
fi

if [[ "$failed" -ne 0 ]]; then
    exit 1
fi

fork_history_base="270db084796cec47245c0c5fa5ca21b6d222ea76"
# Reviewed public upstream history. Keep its original attribution; only fork-authored
# descendants must use our privacy-preserving identity. Advance this pinned boundary
# explicitly after reviewing a new sw33tLie/macshot upstream revision.
upstream_history_base="43d5ae4852ec5b991a577a3dd0f254cbda93ae51"
git cat-file -e "${fork_history_base}^{commit}" 2>/dev/null || {
    echo "Privacy check failed: the fork history boundary is unavailable." >&2
    exit 1
}
git cat-file -e "${upstream_history_base}^{commit}" 2>/dev/null || {
    echo "Privacy check failed: the reviewed upstream history is unavailable." >&2
    exit 1
}

while IFS= read -r commit; do
    author_name="$(git show -s --format='%an' "$commit")"
    author_email="$(git show -s --format='%ae' "$commit")"
    committer_name="$(git show -s --format='%cn' "$commit")"
    committer_email="$(git show -s --format='%ce' "$commit")"
    parents="$(git show -s --format='%P' "$commit")"

    case "${author_name} <${author_email}>" in
        "MacShot Fork Maintainers <macshot-maintainers@users.noreply.github.com>"|\
        "github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>")
            continue
            ;;
    esac

    if [[ "$committer_name" == "GitHub" \
        && "$committer_email" == "noreply@github.com" \
        && "$author_email" =~ ^[0-9]+\+[^@]+@users\.noreply\.github\.com$ \
        && "$parents" == *" "* ]]; then
        continue
    fi

    echo "Privacy check failed: fork commits contain an unexpected author identity." >&2
    exit 1
done < <(git rev-list "${fork_history_base}..HEAD" --not "$upstream_history_base")

echo "Public-repository privacy checks passed."
