#!/usr/bin/env bash
# Sync this fork with microsoft/markitdown (fetch-only upstream; push only to origin).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
ORIGIN_REMOTE="${ORIGIN_REMOTE:-origin}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
UPSTREAM_URL="${UPSTREAM_URL:-git@github.com:microsoft/markitdown.git}"

usage() {
  cat <<'EOF'
Usage: scripts/sync-upstream.sh <command> [options]

Commands:
  status              Show how this branch compares to upstream/main
  sync [--rebase]     Fetch upstream and merge (default) or rebase onto upstream/main
  push                Push the current branch to origin only
  ensure-remotes      Create/fix upstream (fetch-only) and verify origin

Options:
  --force-dirty       Allow sync with a dirty working tree (not recommended)
  --branch <name>     Upstream branch to sync from (default: main)
  -h, --help          Show this help

Examples:
  ./scripts/sync-upstream.sh status
  ./scripts/sync-upstream.sh sync
  ./scripts/sync-upstream.sh sync --rebase
  ./scripts/sync-upstream.sh push
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

info() {
  echo "→ $*"
}

require_git_repo() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repository: $ROOT"
}

current_branch() {
  local branch
  branch="$(git rev-parse --abbrev-ref HEAD)"
  [[ "$branch" != "HEAD" ]] || die "detached HEAD; checkout a branch first"
  echo "$branch"
}

working_tree_dirty() {
  ! git diff --quiet || ! git diff --cached --quiet || [[ -n "$(git ls-files --others --exclude-standard)" ]]
}

ensure_remotes() {
  if ! git remote get-url "$ORIGIN_REMOTE" >/dev/null 2>&1; then
    die "remote '$ORIGIN_REMOTE' is missing (your fork)"
  fi

  if ! git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
    info "adding $UPSTREAM_REMOTE → $UPSTREAM_URL"
    git remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
  fi

  # Never allow pushes to the original MarkItDown repo.
  git remote set-url --push "$UPSTREAM_REMOTE" no_push

  info "remotes:"
  git remote -v
}

fetch_upstream() {
  info "fetching $UPSTREAM_REMOTE/$UPSTREAM_BRANCH"
  git fetch "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH"
}

cmd_status() {
  ensure_remotes
  fetch_upstream
  local branch
  branch="$(current_branch)"
  local upstream_ref="$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"

  local behind ahead
  behind="$(git rev-list --count "HEAD..$upstream_ref")"
  ahead="$(git rev-list --count "$upstream_ref..HEAD")"

  echo
  echo "branch:   $branch"
  echo "upstream: $upstream_ref"
  echo "behind:   $behind commit(s)"
  echo "ahead:    $ahead commit(s) (your fork-only work)"
  echo

  if [[ "$behind" -gt 0 ]]; then
    echo "New on upstream (not in your branch yet):"
    git log --oneline --no-decorate "HEAD..$upstream_ref" | head -n 15
    [[ "$behind" -gt 15 ]] && echo "... and $((behind - 15)) more"
    echo
    echo "Run: ./scripts/sync-upstream.sh sync"
  else
    echo "Already up to date with $upstream_ref."
  fi
}

cmd_sync() {
  local rebase=false
  local force_dirty=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --rebase) rebase=true ;;
      --force-dirty) force_dirty=true ;;
      --branch)
        shift
        [[ $# -gt 0 ]] || die "--branch requires a name"
        UPSTREAM_BRANCH="$1"
        ;;
      *) die "unknown sync option: $1" ;;
    esac
    shift
  done

  ensure_remotes

  if working_tree_dirty && [[ "$force_dirty" != true ]]; then
    die "working tree has uncommitted changes; commit/stash them, or pass --force-dirty"
  fi

  local branch
  branch="$(current_branch)"
  local upstream_ref="$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"

  fetch_upstream

  if [[ "$rebase" == true ]]; then
    info "rebasing $branch onto $upstream_ref"
    if ! git rebase "$upstream_ref"; then
      die "rebase conflict. Fix conflicts, then: git add ... && git rebase --continue
Or abort with: git rebase --abort"
    fi
  else
    info "merging $upstream_ref into $branch"
    if ! git merge --no-edit "$upstream_ref"; then
      die "merge conflict. Fix conflicts, then: git add ... && git commit
Or abort with: git merge --abort"
    fi
  fi

  info "sync complete. Push your fork with: ./scripts/sync-upstream.sh push"
}

cmd_push() {
  ensure_remotes
  local branch
  branch="$(current_branch)"

  # Belt-and-suspenders: never push to upstream.
  if [[ "$ORIGIN_REMOTE" == "$UPSTREAM_REMOTE" ]]; then
    die "origin and upstream are the same remote; refusing to push"
  fi

  info "pushing $branch → $ORIGIN_REMOTE (fork only)"
  git push -u "$ORIGIN_REMOTE" "$branch"
  info "done (nothing was pushed to MarkItDown upstream)"
}

main() {
  require_git_repo

  local cmd="${1:-}"
  [[ -n "$cmd" ]] || { usage; exit 1; }
  shift || true

  case "$cmd" in
    -h|--help|help) usage ;;
    ensure-remotes) ensure_remotes ;;
    status)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --branch)
            shift
            [[ $# -gt 0 ]] || die "--branch requires a name"
            UPSTREAM_BRANCH="$1"
            ;;
          *) die "unknown status option: $1" ;;
        esac
        shift
      done
      cmd_status
      ;;
    sync) cmd_sync "$@" ;;
    push) cmd_push ;;
    *) die "unknown command: $cmd (try --help)" ;;
  esac
}

main "$@"
