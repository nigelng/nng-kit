# relay storage

Backend seam for remote handoff storage. Front-ends (the claude.ai chat skill and the Code plugin) name the operations in this file; each backend supplies the call. Layout, locks, and claim-first verbs are in [format.md](format.md).

Personal roots and space names are **not** part of this spec. Code selects a backend with `$RELAY_BACKEND` and a root with `$RELAY_ROOT`. Chat skills supply their own. There is no default root and no default backend.

## Operations

| Operation | Class | Meaning |
| --- | --- | --- |
| `create_if_absent` | sync, atomic | Create a file at a path with the given body. Succeeds only when that path was absent. On conflict, returns the backend's conflict signal: the path already existed, with no overwrite and no autorename. |
| `list` | sync read | List one folder. Follow pagination to the end. An unfinished listing is **unknown** — never guess. |
| `read` | sync read | Return one file's body. |
| `move` | eventual | Move or rename a file or folder. The call may return before the namespace updates. The return value is not a correctness signal. Confirm later with `list`. |
| `delete` | eventual | Remove a file or folder. Same rule as `move`: the return value is not a correctness signal. Confirm later with `list`. |
| `create_folder` | sync, not a claim | Create a folder. An "already exists" result is an ordinary outcome, not a claim. |

`create_if_absent` is the only correctness signal. `move` and `delete` are cleanup.

## `atomic_create`

`atomic_create` means `create_if_absent` is synchronous and exclusive: exactly one concurrent caller succeeds, and every other caller receives the conflict signal.

| Backend | Status | `atomic_create` | Conflict signal |
| --- | --- | --- | --- |
| `dropbox` | implemented | yes, via MCP `create_file` only | `[ALREADY_EXISTS]` |
| `onedrive` | planned / unverified | no, until the mapping below is verified | 409 `nameAlreadyExists` (planned) |
| any other value | unimplemented | no | — |

A backend without `atomic_create` may mirror (write pending files) and must not offer claim-first verbs. Claim-first verbs are Execute, Discard, and lazy expiry, and any create of a file under `locks/`.

An unimplemented backend is **repo-only**: no mirror and no remote calls. `onedrive` stays in that set until a later plan ships an adapter. Do not send that traffic to Dropbox.

## Env

Pick the backend from the environment before any remote call:

- `$RELAY_ROOT` set — backend is `$RELAY_BACKEND`, or `dropbox` when `$RELAY_BACKEND` is unset.
- `$RELAY_ROOT` unset and `$RELAY_DROPBOX_ROOT` set — backend `dropbox`, root `$RELAY_DROPBOX_ROOT`. That name is a deprecated alias.
- Neither root set — repo-only.
- Backend `onedrive`, or any value other than `dropbox` — repo-only. Name the backend in the message.

`$RELAY_LEGACY_ROOT`, when set and different from the active root, accepts `list` and `read`. Claim-first verbs run against the active root. Migration may take a single `superseded` lock in the legacy root so an old surface cannot also act on that id. It never takes `consumed`, `discarded`, or `expired` there, and it never acts on a directive read from that root.

## Repo-only

The committed repo file (path in [format.md](format.md)) is git, not one of the operations above. Repo-only means read, write, and delete that file, and skip every remote operation. Say why: no root, an unimplemented backend, or an unknown backend.

## Dropbox

Implemented. `atomic_create` is MCP `create_file`, which fails synchronously with `[ALREADY_EXISTS]` when the path exists (no overwrite, no autorename).

Paths sit under `<root>`: `$RELAY_ROOT`, or `$RELAY_DROPBOX_ROOT` when only the deprecated alias is set. Role paths (`pending/`, `archive/`, `locks/`) are in [format.md](format.md).

| Operation | Call |
| --- | --- |
| `create_if_absent` | MCP `create_file` |
| `list` | MCP `list_folder` (follow `cursor` / `has_more` to the end) |
| `read` | MCP `fetch` |
| `move` | MCP `move` |
| `delete` | MCP `delete` |
| `create_folder` | MCP `create_folder` |

relay does not call `check_job_status`. After `move` or `delete`, confirm with `list`.

A whole-folder `move` (one root onto another) is **unverified** for MCP `move`. Verify by listing: `pending/`, `locks/`, and `README.md` present at the destination, and the source gone or empty. The move result is not success.

### `dbxcli` fallback

When the MCP tool for an operation is unavailable, `dbxcli` may run non-lock operations: `list`, `read`, `move`, `delete`, `create_folder`, and a pending-file write. Discover the subcommand with `dbxcli … --help --output=json`, then pass `--output=json` on the call. A folder `move` that MCP rejects may use `dbxcli mv`. That call is still eventual: verify by listing.

`dbxcli` upload does not provide `atomic_create`. Its behaviour when the path already exists is unverified, so a `dbxcli` write is not a conflict signal. Lock files (`locks/*.lock`, including rev locks) are created with MCP `create_file` only. When a step needs a lock and MCP `create_file` is unavailable, stop.

## OneDrive

**Planned / unverified. Not implemented.** `$RELAY_BACKEND=onedrive` is repo-only. The table is the contract for the next plan. Skills must not call Graph until that plan verifies the conflict signal and sets `atomic_create` to yes.

Intended `create_if_absent`:

`PUT /me/drive/root:/{item-path}:/content?@microsoft.graph.conflictBehavior=fail`

`{item-path}` is `$RELAY_ROOT` joined with the role-relative path, with no leading slash, then URL-encoded. This spec fixes neither a drive nor a root. A root outside the signed-in user's default drive uses `/drives/{drive-id}/root:/{item-path}:` in place of `/me/drive/root:`.

Planned conflict signal: HTTP **409** whose Graph error `code` is `nameAlreadyExists`. Match the code, not the message text. Recorded as **planned; verify when implementing**: the PUT is atomic, does not overwrite, and does not autorename. The `driveItem` conflictBehavior attribute documents `replace` as the PUT default, and the put-content reference does not describe this parameter or its behaviour under concurrency, so `fail` has to be proven against the real drive. A PUT that omits it is not `create_if_absent`. Treat **201 Created** as success. A **200** that means the item was replaced fails verification; leave `atomic_create` at no.

Lock and handoff bodies use this simple PUT (small files). `createUploadSession` is a different API: a 409 from it can arrive before any file is committed, so it is not `create_if_absent`.

| Operation | Graph call (planned) | Verify |
| --- | --- | --- |
| `create_if_absent` | `PUT …/root:/{item-path}:/content?@microsoft.graph.conflictBehavior=fail` | 201 versus 409 `nameAlreadyExists`. Two concurrent creates of one lock path: exactly one succeeds. |
| `list` | `GET …/root:/{folder-path}:/children` | Follow `@odata.nextLink` until it is absent. A truncated page is **unknown** — never guess. |
| `read` | `GET …/root:/{item-path}:/content` | Follow the redirect and return the body. |
| `move` | `PATCH …/root:/{item-path}` with a new `parentReference` and `name` | 200 or 202. Confirm with `list`. |
| `delete` | `DELETE …/root:/{item-path}` | Not a correctness signal. Confirm with `list`. |
| `create_folder` | `POST …/root:/{parent-path}:/children` with `name`, `"folder": {}`, and `"@microsoft.graph.conflictBehavior": "fail"` | 409 `nameAlreadyExists` when the name is taken. Not a claim. |

Until that conflict check passes, OneDrive has no `atomic_create` and must not offer claim-first verbs. Until the adapter exists, the backend is unimplemented, so it is repo-only (no mirror either).

### Auth prerequisites (next plan)

Auth, token storage, and the HTTP client are out of scope here. The next plan needs all of the following before the first OneDrive call:

1. An Entra app registration. Least privileged delegated scope for the content PUT is `Files.ReadWrite`. Use `Files.ReadWrite.All` or `Sites.ReadWrite.All` only when the root is outside the signed-in user's default drive. Confirm the scope when implementing.
2. Token acquisition and refresh. Store the token in the OS keychain. Keep it out of the repo, out of `settings.json`, and out of this file.
3. An HTTP client that maps status codes onto the table above. For `create_if_absent`, 409 `nameAlreadyExists` is the conflict signal and 201 is success. Any other 4xx or 5xx, on any operation, is an error. Confirm the service honours `conflictBehavior=fail` on the PUT URL, including however `@` is encoded.
4. The concurrency check in the `create_if_absent` row. `atomic_create` stays no until it passes.
5. claude.ai chat stays on Dropbox. The Microsoft 365 connector's write and create-if-absent support is unverified.

## Which class may do what

| Class | Use |
| --- | --- |
| `create_if_absent` on a backend with `atomic_create` | Terminal locks, rev locks, and any create that must not clobber |
| `create_if_absent` on an implemented backend without `atomic_create` | Pending mirror only. A conflict result from that write is meaningless. |
| `list`, `read` | Lookups. Identity comes from filenames; see [format.md](format.md). |
| `move`, `delete` | Cleanup after a lock is already held, and folder migration. Re-check with `list`. |
| `create_folder` | Make sure `pending/`, `archive/`, and `locks/` exist. |
