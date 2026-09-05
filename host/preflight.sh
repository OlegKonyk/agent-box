#!/bin/bash
#
# agent-box — scan a repository on the host before it is mounted into a VM.
#
# Usage: preflight.sh <repo-path>
#
# Exit codes: 0 clean, 1 findings, 2 usage error.
#
# Output discipline: findings are reported as PATHS ONLY. Never the matching
# line, never the matched secret, never the term that matched. A preflight
# report is something you might paste into a ticket; it must not be the thing
# that leaks what it was looking for.

set -uo pipefail

BLOCKLIST="${AGENT_BOX_BLOCKLIST:-${HOME}/.config/agent-box/blocklist.txt}"

# `git grep` over every reachable commit is O(commits). Capped so preflight
# stays fast on a large repository; the cap is reported when it bites.
HISTORY_COMMIT_CAP="${AGENT_BOX_HISTORY_COMMIT_CAP:-2000}"

usage() {
    cat >&2 <<'EOF'
usage: preflight.sh <repo-path>

Scans a repository for secrets and for locally-configured terms before it is
mounted into an agent-box VM. Reports paths only.

  exit 0  clean
  exit 1  findings
  exit 2  usage error
EOF
}

[ $# -eq 1 ] || { usage; exit 2; }
REPO="$1"
[ -d "$REPO" ] || { printf 'preflight: not a directory: %s\n' "$REPO" >&2; exit 2; }
REPO=$(cd "$REPO" && pwd)

command -v gitleaks >/dev/null 2>&1 || { printf 'preflight: gitleaks is not installed (brew install gitleaks)\n' >&2; exit 2; }

TMP=$(mktemp -d -t agent-box-preflight.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

hr() { printf '%s\n' '--------------------------------------------------------------'; }

# `grep -c` exits 1 on zero matches, so it cannot be combined with a `||`
# fallback without printing the count twice.
count_lines() {
    local n
    n=$(wc -l < "$1" 2>/dev/null) || n=0
    printf '%s' "${n//[[:space:]]/}"
}

printf 'agent-box preflight: %s\n' "$REPO"
hr

# ---------------------------------------------------------------------------
# 1. gitleaks — working tree, and history when there is any
# ---------------------------------------------------------------------------

secret_paths="${TMP}/secret_paths"
: > "$secret_paths"

collect_gitleaks() {
    local report="$1"
    [ -s "$report" ] || return 0
    jq -r '.[] | "\(.File)\t\(.RuleID)"' "$report" 2>/dev/null >> "$secret_paths" || true
}

printf 'gitleaks: scanning the working tree...\n'
gitleaks dir --no-banner --no-color --redact --log-level error --exit-code 1 \
    --report-format json --report-path "${TMP}/dir.json" "$REPO" >/dev/null 2>&1
collect_gitleaks "${TMP}/dir.json"

is_git=0
if git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
    is_git=1
    if git -C "$REPO" rev-parse --verify HEAD >/dev/null 2>&1; then
        printf 'gitleaks: scanning git history...\n'
        gitleaks git --no-banner --no-color --redact --log-level error --exit-code 1 \
            --report-format json --report-path "${TMP}/git.json" "$REPO" >/dev/null 2>&1
        collect_gitleaks "${TMP}/git.json"
    else
        printf 'gitleaks: no commits yet; history scan skipped\n'
    fi
else
    printf 'gitleaks: not a git repository; history scan skipped\n'
fi

sort -u -o "$secret_paths" "$secret_paths"
secret_count=$(count_lines "$secret_paths")

# ---------------------------------------------------------------------------
# 2. Locally-configured terms
# ---------------------------------------------------------------------------
#
# The term list itself lives outside this repository and is never printed.

term_paths="${TMP}/term_paths"
: > "$term_paths"
term_status="skipped"

if [ -f "$BLOCKLIST" ]; then
    terms="${TMP}/terms"
    sed -e 's/#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$BLOCKLIST" | grep -v '^$' > "$terms" || true
    if [ -s "$terms" ]; then
        printf 'terms: scanning for %s configured term(s) (terms are never printed)...\n' "$(count_lines "$terms")"
        # -l: filenames only. -I: skip binaries. -F -i: literal, case-insensitive.
        grep -r -l -I -F -i -f "$terms" "$REPO" --exclude-dir=.git 2>/dev/null > "$term_paths" || true
        term_status="scanned"

        # The whole .git directory is mounted into the VM, so the agent can read
        # every object in it. A term that survives only in a commit message, a
        # deleted file, or an abandoned branch is just as readable as one in the
        # working tree — and the cleanroom rule is the reason this check exists
        # at all, so it must not be the one with the blind spot.
        if [ "$is_git" -eq 1 ] && git -C "$REPO" rev-parse --verify HEAD >/dev/null 2>&1; then
            printf 'terms: scanning git history (all refs)...\n'
            term_status="scanned+history"

            revs=$(git -C "$REPO" rev-list --all 2>/dev/null | head -n "$HISTORY_COMMIT_CAP" || true)

            # Commit messages and authorship, across every ref.
            while read -r sha; do
                [ -n "$sha" ] || continue
                if git -C "$REPO" log -1 --format='%B%n%an%n%ae' "$sha" 2>/dev/null \
                    | grep -q -I -F -i -f "$terms"; then
                    printf 'commit message %s\n' "$sha" >> "$term_paths"
                fi
            done < <(printf '%s\n' "$revs")

            # Ref names themselves can carry a term.
            git -C "$REPO" for-each-ref --format='%(refname)' 2>/dev/null \
                | grep -I -F -i -f "$terms" 2>/dev/null \
                | sed 's|^|ref |' >> "$term_paths" || true

            # File content across every reachable commit. `git grep` reports
            # <rev>:<path>, which is a location, not content.
            if [ -n "$revs" ]; then
                # shellcheck disable=SC2086  # deliberate splitting: git grep takes a rev list.
                git -C "$REPO" grep -I -l -F -i -f "$terms" $revs 2>/dev/null \
                    | sed 's|^|history |' >> "$term_paths" || true
            fi

            total_commits=$(git -C "$REPO" rev-list --count --all 2>/dev/null || printf '0')
            if [ "$total_commits" -gt "$HISTORY_COMMIT_CAP" ]; then
                printf 'terms: NOTE — history scan capped at the %s most recent commits of %s\n' \
                    "$HISTORY_COMMIT_CAP" "$total_commits"
            fi
        else
            printf 'terms: no commits; history scan skipped\n'
        fi

        sort -u -o "$term_paths" "$term_paths"
    else
        printf 'terms: %s is empty; scan skipped\n' "$BLOCKLIST"
    fi
else
    printf 'terms: no blocklist at %s; scan skipped\n' "$BLOCKLIST"
fi
term_count=$(count_lines "$term_paths")

# ---------------------------------------------------------------------------
# 3. Credential-shaped files
# ---------------------------------------------------------------------------

cred_paths="${TMP}/cred_paths"
: > "$cred_paths"

if [ "$is_git" -eq 1 ] && git -C "$REPO" rev-parse --verify HEAD >/dev/null 2>&1; then
    # Tracked files only: an ignored, untracked .env is the intended way to
    # hold local config and is not a finding on its own.
    git -C "$REPO" ls-files -z \
        | tr '\0' '\n' \
        | grep -E '(^|/)(\.env($|\..*)|id_rsa.*|id_dsa.*|id_ecdsa.*|id_ed25519.*)$|\.(pem|p12|pfx|key|jks|keystore)$' \
        | sed "s#^#${REPO}/#" >> "$cred_paths" 2>/dev/null || true
fi

# Private key material anywhere in the tree, tracked or not.
grep -r -l -I -E -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' "$REPO" --exclude-dir=.git 2>/dev/null >> "$cred_paths" || true

sort -u -o "$cred_paths" "$cred_paths"
cred_count=$(count_lines "$cred_paths")

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

hr
if [ "$secret_count" -gt 0 ]; then
    printf '\nSECRETS (%s) — path and rule, value redacted:\n' "$secret_count"
    while IFS=$'\t' read -r f rule; do
        printf '  %-52s %s\n' "$f" "$rule"
    done < "$secret_paths"
fi

if [ "$term_count" -gt 0 ]; then
    printf '\nCONFIGURED TERMS (%s) — locations only, never the term:\n' "$term_count"
    sed 's/^/  /' "$term_paths"
fi

if [ "$cred_count" -gt 0 ]; then
    printf '\nCREDENTIAL-SHAPED FILES (%s) — paths only:\n' "$cred_count"
    sed 's/^/  /' "$cred_paths"
fi

total=$((secret_count + term_count + cred_count))

printf '\n'
hr
printf '%-34s %8s\n' 'CHECK' 'FINDINGS'
hr
printf '%-34s %8s\n' 'gitleaks secrets' "$secret_count"
printf '%-34s %8s\n' "configured terms (${term_status})" "$term_count"
printf '%-34s %8s\n' 'credential-shaped files' "$cred_count"
hr
printf '%-34s %8s\n' 'TOTAL' "$total"
hr

if [ "$total" -gt 0 ]; then
    printf '\npreflight: FAIL — resolve the findings above, or mount a different repository.\n'
    exit 1
fi

printf '\npreflight: PASS — nothing found.\n'
exit 0
