#!/usr/bin/env bash
set -euo pipefail

# Computes:
# - DEFAULT_BRANCH: what Super-Linter should treat as "default" for its internal comparisons.
# - checkout_repository + checkout_ref: so PRs lint the *head repo/branch* (fork), not the base repo.
#
# Behavior:
# - pull_request: lint the fork/head branch (checkout PR head SHA); DEFAULT_BRANCH becomes PR head ref
#   (so it exists in the checked-out repo).
# - workflow_dispatch: lint the selected ref (branch) if possible; otherwise fall back to the repo's
#   configured default branch (from GitHub settings), not hardcoded "main".

EVENT_NAME="${GITHUB_EVENT_NAME:-}"
EVENT_PATH="${GITHUB_EVENT_PATH:-}"
REF_NAME="${GITHUB_REF_NAME:-}"
REF_TYPE="${GITHUB_REF_TYPE:-}" # "branch" or "tag" (often set on workflow_dispatch)

# Helper to read JSON safely. Ubuntu runners normally have jq, but fallback to python if not.
json_get() {
  local filter="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -r "$filter // empty" "$EVENT_PATH"
  else
    python3 - <<'PY' "$EVENT_PATH" "$filter"
import json, sys
path, flt = sys.argv[1], sys.argv[2]
data = json.load(open(path))
# Minimal, specific filters we use below:
def get(d, keys):
  for k in keys:
    if not isinstance(d, dict) or k not in d: return ""
    d = d[k]
  return d if isinstance(d, str) else ""
m = {
  ".repository.default_branch": get(data, ["repository","default_branch"]),
  ".repository.full_name": get(data, ["repository","full_name"]),
  ".pull_request.head.ref": get(data, ["pull_request","head","ref"]),
  ".pull_request.head.sha": get(data, ["pull_request","head","sha"]),
  ".pull_request.head.repo.full_name": get(data, ["pull_request","head","repo","full_name"]),
}
print(m.get(flt, ""))
PY
  fi
}

repo_default_branch="$(json_get '.repository.default_branch')"
repo_full_name="$(json_get '.repository.full_name')"

# Extra fallback: ask git what origin's HEAD branch is (after checkout), but we avoid relying on it here.
# We'll only use this if the event payload lacks repository.default_branch.
if [[ -z "$repo_default_branch" ]]; then
  repo_default_branch="main" # last-resort; should rarely happen
fi

checkout_repository="$repo_full_name"
checkout_ref="${GITHUB_SHA:-}"

DEFAULT_BRANCH=""

case "$EVENT_NAME" in
  pull_request)
    pr_head_ref="$(json_get '.pull_request.head.ref')"
    pr_head_sha="$(json_get '.pull_request.head.sha')"
    pr_head_repo="$(json_get '.pull_request.head.repo.full_name')"

    # Lint the fork/head branch, not the base repo merge ref:
    if [[ -n "$pr_head_repo" ]]; then
      checkout_repository="$pr_head_repo"
    fi
    if [[ -n "$pr_head_sha" ]]; then
      checkout_ref="$pr_head_sha"
    fi

    # For your stated intent: set DEFAULT_BRANCH to the head ref so it exists in the checked-out repo.
    # (If you later switch Super-Linter into diff-against-base mode, you'd set this to base.ref instead.)
    if [[ -n "$pr_head_ref" ]]; then
      DEFAULT_BRANCH="$pr_head_ref"
    else
      DEFAULT_BRANCH="$repo_default_branch"
    fi
    ;;

  workflow_dispatch)
    # Prefer linting the branch the user selected in the UI.
    if [[ "$REF_TYPE" == "branch" && -n "$REF_NAME" ]]; then
      DEFAULT_BRANCH="$REF_NAME"
    else
      DEFAULT_BRANCH="$repo_default_branch"
    fi

    # Checkout the selected ref explicitly (works for branches; tags are okay too).
    # If REF_NAME is empty, fall back to SHA.
    if [[ -n "${GITHUB_REF:-}" ]]; then
      checkout_ref="${GITHUB_REF}"
    fi
    ;;

  *)
    # Other events: fall back to repo default
    DEFAULT_BRANCH="$repo_default_branch"
    ;;
esac

# Export for later steps
{
  echo "DEFAULT_BRANCH=$DEFAULT_BRANCH"
} >> "$GITHUB_ENV"

# And as step outputs (so checkout can use them)
{
  echo "default_branch=$DEFAULT_BRANCH"
  echo "checkout_repository=$checkout_repository"
  echo "checkout_ref=$checkout_ref"
} >> "$GITHUB_OUTPUT"

echo "[compute-superlinter-refs] EVENT_NAME=$EVENT_NAME"
echo "[compute-superlinter-refs] DEFAULT_BRANCH=$DEFAULT_BRANCH"
echo "[compute-superlinter-refs] checkout_repository=$checkout_repository"
echo "[compute-superlinter-refs] checkout_ref=$checkout_ref"
