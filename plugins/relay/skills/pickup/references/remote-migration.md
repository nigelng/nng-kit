## Remote migration

Run only when **all** of these hold:

- `status` is `on` or `deprecated-alias` (Dropbox, `atomic_create` available).
- `$legacy` is non-empty.
- A finished `list` of the legacy root is **non-empty** (it has content).

Otherwise skip, with a reason when the user might expect a move:

- `status` is `off`, `not-implemented`, `unknown-backend`, or `invalid-root` → no remote calls. Do not move.
- `$legacy` is empty → no legacy root.
- Finished `list` of the legacy root is empty, or the legacy root is not found → nothing to migrate.
- That `list` is unfinished or returns any other error → **unknown**. Do not move and do not adopt.

If **Absent root, before any active-root write** already offered the move in this invocation, do not offer it again. Keep that result (verified move, **Cancel**, empty root, or unknown).

`list` the active root the same way:

| Active root `list` | Action |
| --- | --- |
| Not found (the root is absent) | Offer the whole-folder move below, before any `create_folder` or `create_if_absent` on `<root>`. Do not create `<root>` while it stays absent and the legacy root has content. |
| Finished listing with one or more entries | The root **exists with content**. Refuse the whole-folder move. Go to **Straggler adoption**. |
| Finished listing with zero entries | The root **exists and is empty**. Do **not** move onto it (a folder move is only for an absent root) and do **not** write into it (writes would create content and block a later folder move). Say so. Tell the user that removing the empty active root outside this skill, then running pickup again, is what makes the folder move possible. Stop this section. |
| Unfinished, or any error that is not not-found | **Unknown**. Do not move and do not adopt. |

### Whole-folder move

Ask (single-select): **Move folder / Cancel**. The confirm states both preconditions, and the user must accept them:

- Every machine has rebuilt, so no relay 0.2 is still claiming in the legacy root.
- No chat pickup or save is mid-flight.

Also say: do not upload the updated chat skill before this move. Upload it immediately after `list` confirms the destination.

On **Cancel**: leave both roots untouched. Do **not** start straggler adoption. Do not `create_folder` or `create_if_absent` on `<root>` later in this invocation. Copying or locking there would create the active root and block a later folder move.

On **Move folder**:

1. `move` the legacy folder to `<root>`. Prefer Dropbox MCP `move`. If MCP rejects the folder move, `dbxcli mv` is allowed only when the Dropbox MCP `create_file` tool is available — it is not a lock operation. Pass the two configured roots as separate arguments. Do not move listed children one by one.
2. The `move` result is **not** success. Ignore it as a correctness signal.
3. Verify with `list`, after the namespace has had a chance to update. Success means all of these:
   - `<root>/pending/` is present
   - `<root>/locks/` is present
   - `<root>/README.md` is present
   - the legacy root is not found, or a finished `list` of it is empty
4. If any `list` in that check is unfinished, verification is **unknown**. Do not say the move succeeded. Do not tell the user to upload the chat skill yet. They can run pickup again to re-check.
5. When verification succeeds: say the folder is at the active root. **Tell the user to upload the updated relay chat skill now**, before another chat pickup or save. Do not name a personal remote path.
6. When verification fails (a required name is absent, or the legacy root still has content): say the move is not confirmed. Do not start straggler adoption on top of an unconfirmed move. Do not tell the user to upload yet.

A legacy root that has no `README.md` cannot pass step 3. Do not invent that file.
