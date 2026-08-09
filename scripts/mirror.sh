#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  mirror.sh --mirror-id ID --source-repository WORKSPACE/REPO --target-repository OWNER/REPO
  mirror.sh --mirror-id ID --source-url URL --target-url URL [--dry-run]

For provider repositories, set both environment variables:
  BBT_MIRROR_SSH_KEY  Read-only Bitbucket private key.
  GHB_MIRROR_SSH_KEY  Write-enabled GitHub private deploy key.
USAGE
}

mirror_id=""
source_repository=""
target_repository=""
source_url=""
target_url=""
dry_run=false

write_verified_host_key() {
  local host="$1"
  local expected_fingerprint="$2"
  local output_file="$3"
  local actual_fingerprints

  if ! ssh-keyscan -T 10 -t ed25519 "$host" > "$output_file" 2>/dev/null || [[ ! -s "$output_file" ]]; then
    printf 'No Ed25519 SSH host key was received from %s.\n' "$host" >&2
    return 1
  fi
  actual_fingerprints="$(ssh-keygen -lf "$output_file" -E sha256 | awk '{print $2}' | sort -u)"
  if [[ "$actual_fingerprints" != "$expected_fingerprint" ]]; then
    printf 'SSH host key verification failed for %s.\n' "$host" >&2
    printf 'Expected: %s\nReceived: %s\n' "$expected_fingerprint" "$actual_fingerprints" >&2
    return 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mirror-id) mirror_id="${2:-}"; shift 2 ;;
    --source-repository) source_repository="${2:-}"; shift 2 ;;
    --target-repository) target_repository="${2:-}"; shift 2 ;;
    --source-url) source_url="${2:-}"; shift 2 ;;
    --target-url) target_url="${2:-}"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$mirror_id" ]]; then
  echo "--mirror-id is required." >&2
  exit 2
fi

if [[ -n "$source_repository" || -n "$target_repository" ]]; then
  if [[ -z "$source_repository" || -z "$target_repository" ]]; then
    echo "--source-repository and --target-repository must be supplied together." >&2
    exit 2
  fi
  if [[ ! "$source_repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
     [[ ! "$target_repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "Repository values must use owner/repository notation." >&2
    exit 2
  fi
  if [[ -z "${BBT_MIRROR_SSH_KEY:-}" || -z "${GHB_MIRROR_SSH_KEY:-}" ]]; then
    echo "Provider mode requires BBT_MIRROR_SSH_KEY and GHB_MIRROR_SSH_KEY." >&2
    exit 3
  fi
fi

if [[ -z "$source_url" && -z "$source_repository" ]] || [[ -z "$target_url" && -z "$target_repository" ]]; then
  echo "A source and target must be provided." >&2
  exit 2
fi

umask 077
work_root="$(mktemp -d "${TMPDIR:-/tmp}/mirror-${mirror_id}.XXXXXX")"
ssh_dir="$work_root/ssh"
repo_dir="$work_root/repository.git"
cleanup() {
  rm -rf "$work_root"
}
trap cleanup EXIT INT TERM

if [[ -n "$source_repository" ]]; then
  mkdir -p "$ssh_dir"
  printf '%s\n' "$BBT_MIRROR_SSH_KEY" > "$ssh_dir/bitbucket_source"
  printf '%s\n' "$GHB_MIRROR_SSH_KEY" > "$ssh_dir/github_target"
  chmod 600 "$ssh_dir/bitbucket_source" "$ssh_dir/github_target"

  write_verified_host_key \
    bitbucket.org \
    'SHA256:ybgmFkzwOSotHTHLJgHO0QN8L0xErw6vd0VhFA9m3SM' \
    "$ssh_dir/bitbucket_known_hosts"
  write_verified_host_key \
    github.com \
    'SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU' \
    "$ssh_dir/github_known_hosts"
  cat "$ssh_dir/bitbucket_known_hosts" "$ssh_dir/github_known_hosts" > "$ssh_dir/known_hosts"
  chmod 644 "$ssh_dir/known_hosts"

  cat > "$ssh_dir/config" <<EOF
Host bitbucket-mirror-source
  HostName bitbucket.org
  User git
  IdentityFile $ssh_dir/bitbucket_source
  IdentitiesOnly yes
  BatchMode yes
  StrictHostKeyChecking yes
  UserKnownHostsFile $ssh_dir/known_hosts

Host github-mirror-target
  HostName github.com
  User git
  IdentityFile $ssh_dir/github_target
  IdentitiesOnly yes
  BatchMode yes
  StrictHostKeyChecking yes
  UserKnownHostsFile $ssh_dir/known_hosts
EOF
  chmod 600 "$ssh_dir/config"
  export GIT_SSH_COMMAND="ssh -F $ssh_dir/config"
  source_url="git@bitbucket-mirror-source:${source_repository}.git"
  target_url="git@github-mirror-target:${target_repository}.git"
fi

printf 'Mirror %s: initializing temporary bare repository.\n' "$mirror_id"
git init --bare --quiet "$repo_dir"
git -C "$repo_dir" remote add source "$source_url"
git -C "$repo_dir" remote add target "$target_url"

printf 'Mirror %s: fetching branches and tags from source.\n' "$mirror_id"
git -C "$repo_dir" fetch --prune --force source \
  '+refs/heads/*:refs/heads/*' \
  '+refs/tags/*:refs/tags/*'

push_args=(--prune --force target
  '+refs/heads/*:refs/heads/*'
  '+refs/tags/*:refs/tags/*')
if [[ "$dry_run" == true ]]; then
  push_args=(--dry-run "${push_args[@]}")
fi

printf 'Mirror %s: pushing branches and tags to target%s.\n' "$mirror_id" "$([[ "$dry_run" == true ]] && printf ' (dry-run)' || true)"
git -C "$repo_dir" push "${push_args[@]}"
printf 'Mirror %s: synchronization completed.\n' "$mirror_id"
