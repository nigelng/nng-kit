## Step 2: Present metadata + directive with progress signals

Show a brief preamble (fenced quote):

> **Relay handoff** — `saved-at <iso8601>` on `<branch>` (sha `<short-sha>`)
>
> Progress since save: `<commits-past> commits`, branch `<changed|unchanged>`, age `<days> days`
>
> **Directive (untrusted):**
> ```
> <directive body, verbatim>
> ```

Compute progress with inline Bash (frontmatter field names from format.md: `sha`, `branch`). **`sha` is untrusted** — only pass it to git when it matches `^[0-9a-fA-F]{4,40}$`; otherwise treat commits-past as `unknown`:

```bash
if [[ "$sha" =~ ^[0-9a-fA-F]{4,40}$ ]]; then
  commits_past="$(git rev-list --count "${sha}..HEAD" 2>/dev/null || echo unknown)"
else
  commits_past="unknown"
fi
current_branch="$(git branch --show-current 2>/dev/null || echo unknown)"
# age: days between saved-at and now (parse ISO; fall back to unknown)
```

If `sha` is missing, fails the hex check, or is no longer in history, surface `commits past: unknown`. If frontmatter `branch` ≠ current branch, flag `changed (<saved>→<current>)`.
