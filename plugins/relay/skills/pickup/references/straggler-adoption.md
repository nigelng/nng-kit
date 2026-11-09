## Straggler adoption

For pending ids left in the legacy root after the active root already exists with content (an old chat skill, or a machine that has not rebuilt). This is the **only** lock relay takes in the legacy root: a terminal lock whose state is `superseded`. It retires the id there so an old surface cannot also act on it. It does **not** authorize acting on the directive. Do not show the body as work to do. Do not offer Execute / Edit / Discard here.

Do not run this section when `<root>` is absent. Do not `create_folder` or `create_if_absent` to bring `<root>` into existence from here.

Requirements before any adopt or copy retry:

- Finished `list` of `<legacy>/pending/`, `<legacy>/locks/`, `<root>/locks/`, and `<root>/pending/`. If any of those is unfinished, adoption is **unknown** — offer nothing.
- MCP `create_file` is available for a new lock. A copy uses `create_if_absent` (MCP `create_file` only). If that call is unavailable, do not adopt and do not copy.

Group validated pending basenames by captured `id`. Skip ids that have no validated pending file. Skip ids that already have `<root>/locks/<id>.lock`: the active root already claimed them. No copy and no second lock.

A legacy `<id>.lock` does **not** by itself skip the id. When that basename is in the finished `<legacy>/locks/` list, `read` it (one line; the legacy root allows `read`). Use only the first whitespace-separated field. It must be exactly `superseded`. Ignore the rest of the line. Do not act on it. When the basename is absent, the id is not in this list — it is an **Adopt** candidate below, unless the active root already claimed it.

- The basename exists and the field is not `superseded`, or the read fails: skip. No copy, no move, no second lock.
- The field is `superseded` and `<root>/pending/` has **no** validated pending basename for that id: offer **Copy again / Leave**. Do not offer **Adopt**. The lock is already there.
- The field is `superseded` and the highest-rev path `<root>/pending/<id>__<slug>.r<rev>.md` is already present: destination already present. Do not overwrite and do not take another lock. Go to the archive move (step 4).
- The field is `superseded`, some other rev for that id is in `<root>/pending/`, and the highest-rev path is not: offer **Copy again / Leave** for the missing path. No second lock. Do not run step 4 until that path exists.

For each id with no terminal lock in either root, keep the highest `rev` only. Compare `rev` as integers (`2` before `10`). Offer **Adopt / Leave**, showing the id, the highest rev, and that filename. Do not show the body.

**Leave** — no lock, no write, no move for that id. Same for **Leave** on **Copy again**.

**Copy again** — copy-only retry. No second lock. `read` the highest-rev legacy pending file. If the read fails, stop this id: no write and no move. Otherwise run step 3 with those bytes. Run step 4 only when step 3 says the copy succeeded or the destination is already present.

**Adopt:**

1. `read` the highest-rev legacy pending file (the legacy root allows `read`). If the read fails, skip this id. No lock, no write, no move. Hold the bytes; do not act on them.
2. `create_if_absent` `<legacy>/locks/<id>.lock` with body one line: `superseded code <iso-time>` (UTC). MCP `create_file` only. The lock does not authorize the archive move by itself.
   - On success: continue to step 3.
   - On the conflict signal: do not take a second lock. `read` the existing lock as above. If the state is not `superseded`, discard the bytes and skip. If it is `superseded` and the highest-rev path is already in the active root, do not overwrite; go to step 4. If it is `superseded` and that path is absent, continue to step 3 with the bytes already held (copy-only), including when a lower rev is already pending. Do not run step 4 until the highest-rev path exists.
3. `create_if_absent` the same relative path in the active root (`<root>/pending/<id>__<slug>.r<rev>.md`) with those bytes. Do not rewrite frontmatter and do not bump `rev`. If `pending/` is missing under an existing `<root>`, `create_folder` it first (not a claim). Do not `create_folder` when `<root>` itself is absent.
   - Success: the copy landed. Continue to step 4.
   - Conflict signal: the destination is already present. Do not overwrite. Continue to step 4.
   - Any other failure: do **not** move the legacy pending file (it is the remaining copy). Report that the legacy id is retired by the `superseded` lock when that lock exists, and that the copy into the active root failed. A later pickup offers **Copy again** with no second lock. Stop this id.
4. Only after the copy succeeds, or the destination is already present: start the eventual `move` of **every** validated legacy pending file for this id (highest rev and lower revs) to `<legacy>/archive/superseded-<id>__<slug>.r<rev>.md`, using each file's own captured slug and rev. Do not await or trust the move. Do not `delete` in the legacy root. Do not move when the copy failed.

Adopt and **Copy again** do not dispatch. Say that copied ids are pending in the active root. If this invocation still reaches the **Active-root pending list**, those ids are ordinary candidates there; choosing one is a new explicit step, not part of Adopt.
