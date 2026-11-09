## No branch file

If there is no branch file, run **Legacy import**, the **Orphan pass**, **Migrate legacy repo files**, and **Remote migration** first. If Import created a handoff and the user went through its dispatch, stop: that was actionable. Otherwise:

- If `status` is `off`, `not-implemented`, `unknown-backend`, or `invalid-root`: stop with

  > No relay handoff for this branch. Run `/relay:save` to capture one, or continue with what you're doing.

  When `status` is `not-implemented` or `unknown-backend`, name the backend and say remote pickup is unavailable (repo-only). Skip this message if Import just created a handoff and the user went through its dispatch.

- If `status` is `on` or `deprecated-alias`: run the **Active-root pending list**, unless **Absent root, before any active-root write** left `<root>` uncreated. In that case do not run the list and do not create `<root>`.
