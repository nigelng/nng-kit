## Guard: resolve the repo file

### Branch file (preferred in a git repo)

Resolve the branch slug with inline Bash. The slug comes from the branch name, not from frontmatter:

```bash
branch="$(git branch --show-current 2>/dev/null || true)"
if [ -n "$branch" ]; then
  slug="$(printf '%s' "$branch" | sed 's|/|--|g' | sed 's/[^A-Za-z0-9._-]/-/g')"
else
  short="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  slug="detached-${short}"
fi
file_relay="docs/relay/${slug}.md"
file_legacy="docs/handoffs/${slug}.md"
path_note=""
if [ -f "$file_relay" ]; then
  file="$file_relay"
  if [ -f "$file_legacy" ]; then
    path_note="Duplicate: $file_legacy also exists; using $file_relay."
  fi
elif [ -f "$file_legacy" ]; then
  file="$file_legacy"
  path_note="Legacy repo path. Edit and Save for later rewrite it to docs/relay/ with git mv."
else
  file=""
fi
```

If `$file` is set, show `$path_note` when it is non-empty, then continue with **Step 1 (repo)**. When the branch-file flow ends (for Execute: after the claim and file deletion, before acting), go to **Legacy import**, the **Orphan pass**, **Migrate legacy repo files**, and **Remote migration**, then stop (the pending list is only for the no-branch-file case).

Execute and Discard work on the located file, including a legacy path. They delete that file. They do not `git mv` it.
