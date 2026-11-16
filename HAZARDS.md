# jj hazards for multiple writers

Measured behaviour of Jujutsu (jj) that causes damage when several agents, or agents and humans,
write to one repository. Most of it barely matters for one person in one checkout.

The findings come from the reproductions and incident notes in
[CodeAlive-AI/jj-agentic-workflow](https://github.com/CodeAlive-AI/jj-agentic-workflow) at commit
`4bd64e1` (2026-11-08). "Seen on" names the jj versions the reproduction ran on. Sections marked
**Script** are re-checked by [`tests/hazards.sh`](tests/hazards.sh) against whatever jj you have
installed; the rest have not been re-run in this fork.

## 1. Reads write

`jj status`, `jj log`, `jj diff` and `jj op log` snapshot the working copy before doing anything
else. In the reproduction each of them created an operation and pulled a stray file into the
current change. `--ignore-working-copy` did not.

A bare command run in someone else's workspace snapshots their files into their change. If their
`@` is already an ancestor of trunk, that rewrites trunk history. Inspect other workspaces with
`jj -R <root> --ignore-working-copy --at-op=@ <cmd>`.

Seen on 0.44 and 0.46. **Script §1.**

## 2. No untracked state, and captured secrets persist

Any file not covered by an ignore rule joins the current change on the next jj command, including
the commands that look like reads.

Ignoring a file jj already tracks changes nothing: it stays tracked and keeps snapshotting new
edits. The order is: add the ignore rule, then `jj file untrack <path>` (the file stays on disk).

After a `.env` was untracked, ignored and deleted, its value was still printable from an earlier
entry in that change's `jj evolog`. The evolution log is local and never pushed, but the value is
in repository storage. Treat it as an exposed credential and rotate it. Purging the hidden commits
(`jj abandon`, `jj util gc`) does not replace rotation.

Related settings:
- `snapshot.max-new-file-size` (1 MiB default): a larger new file makes every jj command fail, and
  nothing is recorded while snapshotting fails.
- `snapshot.auto-track` can exclude paths. On 0.45.1 excluded files show as `Untracked paths` in
  `jj status` and `jj file track` adds one deliberately. Setting it to `none()` globally means a
  forgotten `jj file track` silently leaves real new files out.

Seen on 0.44 (auto-track on 0.45.1). **Script §2.**

## 3. Undo and op restore

On 0.44 and 0.45, `jj undo` in one workspace reverted another workspace's work. Since 0.46,
`jj undo` and `jj redo` refuse an operation made in another workspace unless given
`--allow-cross-workspace`.

`jj op restore <op>` still rewinds the whole repository, other workspaces included. The 0.46
guard also does not cover old operations recorded without workspace metadata, or two agents
sharing one workspace.

Forward fixes left the other writer intact: `jj new <lost-commit>`, `jj restore --from <rev>`, a
scoped `jj describe` or `jj abandon`. Mutating under `--at-op` forks the operation log; use it for
reading.

Seen on 0.44 and 0.46. **Script §3.**

## 4. A deleted Git ref can delete file content

With the default `git.abandon-unreachable-commits = true`, jj's Git import abandons commits that
became unreachable in Git and rebases their descendants.

Reproduction: commit A adds `work.txt` under bookmark `feature`, its child B adds `more.txt`, then
the Git branch is deleted (`git branch -D`, an IDE, a cleanup script). After the next jj command A
was abandoned and `work.txt` was gone from B's tree. With the setting `false` the file survived.

The cost of `false`: unreachable heads accumulate instead of being cleaned up. List them with
`jj log -r 'heads(all() & ~::bookmarks() & ~::remote_bookmarks() & ~empty())'`.

Seen on 0.44 (default case) and 0.46 (`false` case). **Script §4** checks both.

## 5. A background `git fetch` moves bookmarks

In a colocated repository jj imports `refs/remotes/*` on its next command and merges them into
tracked bookmarks. After a plain `git fetch`:
- local `main` had not moved: it fast-forwarded to the remote tip. Trunk moved without anyone
  moving it.
- local `main` had moved and was not pushed: it became conflicted (`main??`), and every command
  naming `main` failed until reconciled.

Desktop agent apps fetch in the background, create a Git worktree per session and clean
worktrees up. Each of those is a writer jj does not know about.

Seen on 0.44. Not scripted.

## 6. Conflicted bookmarks look healthy from Git

jj exports only one side of a conflicted bookmark, so `git branch -v`, `git merge-base` and IDE
panels show one normal-looking `main` and answer questions about an arbitrary side. Diagnose from
jj. Reconcile by rebasing the unpublished side onto the published one, never the reverse:

```sh
jj rebase -s 'roots(bookmarks(exact:"main") & ~::main@origin)' -d main@origin
```

A conflict between a bookmark deletion and an update has only one live target, yet
`.conflict()` is true. Counting targets misses it.

Seen on 0.44; deletion/update case on 0.47.1. Not scripted.

## 7. `jj abandon` moves bookmarks without warning

Abandoning the commit `main` pointed at deleted `main`, reported in the same tone as any success
(`Deleted bookmarks: main`). With `--retain-bookmarks`, `main` moved back to the parent instead.
jj refuses aliases that shadow built-in commands, so `abandon` cannot be wrapped through config.

Revision expressions resolve when a command runs. In a shared working copy, another writer can
move `@` between two of your commands. Observed: agent A abandoned agent B's freshly merged
commit through a shell variable that was correct when assigned.

Before `abandon`, `restore`, `squash` or `rebase -s`, resolve the target to a full commit ID and
read it in the same step. Repair after the fact:
`jj bookmark set main -r 'commit_id("<full id>")'`, then rebase your own change onto it.

Seen on 0.44 and 0.46. **Script §7.**

## 8. Divergent changes do not fail

Concurrent rewrites of one change leave two commits with one change ID (`(divergent)` in
`jj log`). Nothing errors and `main` still resolves. Observed: one twin had the edits, the other
was empty, and trunk was moved onto the empty one.

- `jj converge` (0.45+, experimental) rewrites descendants and moves their bookmarks sideways
  (0.45.1). Use it only when no bookmark sits on the twins or any descendant, and read the
  resulting tree; a clean exit does not mean a correct result.
- `jj squash --from <twin> --into <bookmarked twin>` also moves the bookmark sideways.
- Safer: when the twin with the work already contains trunk,
  `jj new main && jj restore --from 'commit_id("<twin>")'`, then abandon the leftover twins.

Seen on 0.44 and 0.45.1. Not scripted.

## 9. Absence is not an error

A revset that matches nothing returns empty output with exit status 0, so a wrong query looks the
same as "no such commit".

Since 0.37, string patterns in revsets are globs by default, so `description("fix")` does not
match `fix: typo`. Write `description(substring:"fix")`.

A template that reads a missing `Option<Commit>` exits 0 and prints
`<Error: No value set to Option<Commit>>` where JSON was expected (0.47.1). Check the output, not
only the exit status.

Before concluding that work is gone, ask a second way: `jj log -r 'all()'`, `jj evolog`,
`jj op log`. Judge ancestry with `jj log -r 'A::B'` or `git merge-base --is-ancestor A B`, not by
reading a listing.

**Script §9.**

## 10. Workspace creation

- Without `-r`, `jj workspace add` bases the new workspace on the parents of the creator's `@`:
  one commit behind for an agent that just created its task change. **Script §10.**
- Creation snapshots the caller's working copy. `--ignore-working-copy` failed after partial
  creation on 0.46 and is refused up front on 0.47.1. `--at-op=@` still snapshotted the caller; a
  full operation ID did not (0.47.1).
- An invalid or conflicted `-r` printed `Revision ... doesn't exist` and still registered the
  workspace, so the retry failed with "already exists" (0.44). The 0.47.0 changelog lists this as
  fixed.
- Concurrent `jj workspace add` from the same workspace is a known upstream failure mode. Run them
  one at a time.
- A child workspace's `.jj/repo` is a pointer file, not a directory. A watcher reading that
  directory missed every update (0.46).

## 11. The colocated Git view

Git `HEAD` tracks `@-`, detached, not `@`. Git status panels can show the entire current jj change
as uncommitted. jj, not Git, is the source of truth for conflicted bookmarks and ancestry.

## 12. Flags that do not exist

`jj` has no `-q`, and `jj describe` has no `-F`. Use `>/dev/null`, and
`jj describe --stdin < file` or `-m "$(cat file)"`. In an `&&` chain a bad flag stops everything
after it. Re-check after upgrades.

## Agent hosts

A completion (Stop) hook that injected a reminder displaced a substantive answer on 2026-10-16.
The hook's command-contract tests had passed. Upstream retired all completion-blocking hooks after
that.

## Paste into a project AGENTS.md

About 200 tokens. This, not the upstream skills, is the part meant for agent context.

```markdown
## jj safety (multiple writers)
- Every jj command snapshots the working copy, reads included. Inspect another workspace only
  with `jj -R <root> --ignore-working-copy --at-op=@ <cmd>`.
- There is no untracked state. Write scratch output outside the checkout. A file jj already
  tracks needs `jj file untrack` after it is ignored, and stays readable in `jj evolog`: report a
  captured secret as exposed; do not just delete it.
- Recover forward (`jj new <rev>`, `jj restore --from <rev>`). No `jj op restore` while other
  writers share the repo.
- Before `abandon`, `restore`, `squash` or `rebase -s`, resolve the target to a full commit ID and
  read it. Never abandon a commit that a bookmark points at or reaches.
- An empty revset is not an error, and bare string patterns are globs: use
  `description(substring:"x")`. Confirm a surprising absence a second way.
- On `main??` (conflicted bookmark) or `(divergent)` in `jj log`, stop and report before moving
  or pushing anything.
```
