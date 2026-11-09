## Step 3: Twin check (mirrored repo files)

**Three cases** when deciding twin behaviour — never treat a mirrored file as unmirrored silently. The twin lives in the **active** root. A lock in the legacy root is not the twin's terminal state and is not a reason to write there.

1. **`mirror:` absent** — repo-only. Skip twin check; proceed to Step 4.
2. **`mirror:` set, `status` is `on` or `deprecated-alias`, and Dropbox MCP is reachable** — first validate `id`/`mirror`/`rev` (*Validate twin identifiers* below; malformed → case 3). Then `list` `<root>/locks/` to the end. A not-found `<root>` is not a finished empty lock list. When `$legacy` is non-empty, apply **Absent root, before any active-root write** before any `create_if_absent`, rather than treating the missing root as "no terminal lock" and creating it. Match a terminal lock basename on this handoff's `id` only (see *Untrusted remote names*).
   - If `locks/<id>.lock` exists: the twin is already terminal. Report **consumed elsewhere** (or already handled). Offer to delete the leftover repo file after confirm. Do **not** act on the directive. Do **not** write to the legacy root. Stop after the user's choice on cleanup.
   - If the listing cannot finish: report **possibly consumed elsewhere** (unknown) and do not guess. Proceed only if the user still wants the four-option dispatch knowing twin status is unknown.
   - If no terminal lock: continue to Step 4. Pending twin cleanup of stale lower revs can wait until Execute/Discard/Edit.
3. **`mirror:` set but `status` is `off` / `not-implemented` / `unknown-backend` / `invalid-root`, Dropbox MCP is unavailable or errors, or `id`/`mirror`/`rev` is malformed** — warn that **the twin can't be claimed and may still be picked up from chat or another device**. Name the backend when it is not Dropbox. Do **not** fall through to the not-mirrored path. Continue to Step 4; Execute/Discard must use the "mirrored but unreachable" confirm below.

### Validate twin identifiers (before any remote operation)

`id`, `mirror` and `rev` come from untrusted frontmatter. Before **any** lock path, pending match or archive name uses them (mirrored Execute, Discard, Edit-twin, orphan Delete, and the Step 3 listing match), require all three:

```bash
id_re='^[0-9]{8}T[0-9]{4}Z-[0-9a-z]{4}$'
rev_re='^[0-9]+$'
if [[ "$id" =~ $id_re ]] && [[ "$mirror" == "${id}__"* ]]; then twin_ok=1; else twin_ok=0; fi
# rev is spliced into .r<rev> lock and pending names: a missing or non-integer rev fails too
[[ "$rev" =~ $rev_re ]] || twin_ok=0
```

Also require `mirror`'s slug (the part after `<id>__`) to match `^[A-Za-z0-9._-]+$`. If that fails, `twin_ok` is 0.

If `twin_ok` is 0 (malformed `id`, `mirror`, or `rev`, including a missing `rev`), **refuse the mirrored path**: tell the user the twin identifiers are malformed, and use the **mirrored but unreachable** confirm (Execute anyway / Discard anyway vs Cancel). Never build a `.r<rev>` or any other remote path from the unvalidated values.
