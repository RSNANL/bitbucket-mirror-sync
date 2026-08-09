#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_root="$(mktemp -d "${TMPDIR:-/tmp}/mirror-local-test.XXXXXX")"
trap 'rm -rf "$work_root"' EXIT INT TERM
source_repo="$work_root/source.git"
target_repo="$work_root/target.git"
source_work="$work_root/source-work"

git init --bare --quiet "$source_repo"
git init --bare --quiet "$target_repo"
git clone --quiet "$source_repo" "$source_work"
git -C "$source_work" config user.name "Mirror Test"
git -C "$source_work" config user.email "mirror-test@example.invalid"
printf 'initial\n' > "$source_work/file.txt"
git -C "$source_work" add file.txt
git -C "$source_work" commit --quiet -m "Initial"
git -C "$source_work" branch -M main
git -C "$source_work" tag v1.0.0
git -C "$source_work" checkout --quiet -b feature/test
printf 'feature\n' >> "$source_work/file.txt"
git -C "$source_work" commit --quiet -am "Feature"
git -C "$source_work" push --quiet --all origin
git -C "$source_work" push --quiet --tags origin

"$repo_root/scripts/mirror.sh" \
  --mirror-id local-test \
  --source-url "$source_repo" \
  --target-url "$target_repo"

diff -u \
  <(git -C "$source_repo" for-each-ref --format='%(refname) %(objectname)' refs/heads refs/tags | sort) \
  <(git -C "$target_repo" for-each-ref --format='%(refname) %(objectname)' refs/heads refs/tags | sort)

git -C "$source_work" push --quiet origin --delete feature/test
git -C "$source_work" tag -d v1.0.0 >/dev/null
git -C "$source_work" push --quiet origin :refs/tags/v1.0.0
"$repo_root/scripts/mirror.sh" \
  --mirror-id local-test \
  --source-url "$source_repo" \
  --target-url "$target_repo"

if git -C "$target_repo" show-ref --verify --quiet refs/heads/feature/test; then
  echo "Deleted branch was not pruned." >&2
  exit 1
fi
if git -C "$target_repo" show-ref --verify --quiet refs/tags/v1.0.0; then
  echo "Deleted tag was not pruned." >&2
  exit 1
fi

echo "Local branch, tag and prune integration test passed."
