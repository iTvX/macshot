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

if git log --format='%an <%ae>' upstream/main..HEAD 2>/dev/null \
    | grep -Ev '^(MacShot Fork Maintainers <macshot-maintainers@users\.noreply\.github\.com>|github-actions\[bot\] <41898282\+github-actions\[bot\]@users\.noreply\.github\.com>)$' \
    | grep -q .; then
    echo "Privacy check failed: fork commits contain an unexpected author identity." >&2
    exit 1
fi

echo "Public-repository privacy checks passed."
