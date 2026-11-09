## Migrate legacy repo files

On the **default branch** only (same resolution as the orphan pass). Outside a git repo, or when the current branch is not the default, skip silently. If the default branch is unknown, the orphan pass already said so — skip this offer too.

If no `docs/handoffs/*.md` exists, skip silently. Otherwise ask (single-select): **Migrate all / Leave**.

- **Leave** — change nothing.
- **Migrate all** — move every `docs/handoffs/*.md` to `docs/relay/` with `git mv -k` (skip errors; **no clobber**; no `-f`). The moves stay **uncommitted**. Do not `git commit`.

```bash
mkdir -p docs/relay
set -- docs/handoffs/*.md
if [ -e "$1" ]; then
  git mv -k -- "$@" docs/relay/
fi
```

Afterwards, list what `git status --short -- docs/relay docs/handoffs` shows and any `docs/handoffs/*.md` still present (destination already existed, or the source was not a git-tracked file — `-k` skipped it). Do not delete the skips. Do not commit.
