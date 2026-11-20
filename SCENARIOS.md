# Git scenarios

These are exercises for rebase-only GitHub workflows. They start with a single
feature branch and work up to reordering a 5-branch stack. Each scenario keeps
its toy files in its own directory (`s1/`, `s2/`, …). The files are plain text
with one item per line, which makes it easy to build conflicts on purpose.

## Ground rules

- **The main checkout stays on `main` forever.** In it we only run `git fetch`
  and `git pull --ff-only`.
- **Every other branch lives in a worktree** at
  `~/.cache/git-playground/<branch>`. Branch names are flat kebab-case
  (`s1-greeting`), so each one maps to a single directory.
- **No merge commits, ever.** The repo allows *only* rebase merges, and PRs
  land with `gh pr merge --rebase`. To update a branch we use `git rebase` and
  then `git push --force-with-lease`.
- **Merged branches are deleted automatically** (`delete_branch_on_merge`).
  Stacked PRs depend on this. When a parent PR merges and its branch is deleted
  automatically, GitHub retargets the child PR to `main`. If you delete the
  parent branch by hand, GitHub *closes* the child PR instead.
- **"Teammate" changes are simulated** with a `teammate-<topic>` branch in its
  own worktree. It lands through its own rebase-merged PR, the same path real
  changes take.

Handy variables used below:

```sh
MAIN=~/Repositories/git-playground
WT=~/.cache/git-playground
```

### Common recipes

Start a branch off the latest main:

```sh
git -C $MAIN fetch origin
git -C $MAIN worktree add --no-track -b <branch> $WT/<branch> origin/main
```

> `--no-track` matters. Without it the new branch tracks `origin/main`, and a
> bare `git push` / `git pull` points at main. Set the real upstream on the
> first push with `git push -u origin <branch>`.

Clean up after a PR lands:

```sh
git -C $MAIN pull --ff-only
git -C $MAIN worktree remove $WT/<branch>
git -C $MAIN branch -D <branch>      # -D: rebase-merge rewrote the SHAs, so git can't tell it is merged
git -C $MAIN fetch --prune
```

Check that history is still linear (the command should print nothing):

```sh
git -C $MAIN rev-list --merges origin/main
```

---

## Scenario 0: land this document

**Goal:** a warm-up. This file reaches `main` through its own PR.

```sh
git -C $MAIN worktree add --no-track -b docs-scenarios $WT/docs-scenarios origin/main
cd $WT/docs-scenarios
# write SCENARIOS.md
git add SCENARIOS.md && git commit -m "Add SCENARIOS.md"
git push -u origin docs-scenarios
gh pr create --fill
gh pr merge --rebase
# cleanup recipe
```

---

## Scenario 1: simple feature branch

**Goal:** the basic loop: branch, hack, push, PR, rebase-merge, clean up.

1. `worktree add --no-track -b s1-greeting $WT/s1-greeting origin/main`
2. Make 2–3 small commits across a few files, e.g. `s1/greeting.txt` and
   `s1/farewell.txt`, then a tweak to one of them.
3. `git push -u origin s1-greeting`, then `gh pr create --fill`.
4. `gh pr merge --rebase`
5. Run the cleanup recipe.

**Expected:** `origin/main` gains the 2–3 commits on top, with no merge commit.
The SHAs differ from the local ones, because GitHub re-commits them during the
rebase merge.

**Lessons:** use `--no-track` on the worktree branch. Use `-D` rather than `-d`
when deleting a rebase-merged branch.

---

## Scenario 2: someone beats us to main with a conflicting change

**Goal:** resolve a conflict that has already landed upstream before we merge.

1. Branch `s2-config`. Commit an `s2/config.txt` with ~6 `key = value` lines,
   then land that commit as the "seed" through the normal loop. This gives both
   sides a common base.
2. Branch `s2-tuning` (ours) and change `timeout` and `retries`. Push and open a
   PR, but **do not merge**.
3. Branch `teammate-s2-timeout` and change the same `timeout` line to a
   different value. Push, open a PR, and **merge it**.
4. Our PR now reports conflicts. Fix it in our worktree:
   ```sh
   git fetch origin
   git rebase origin/main          # stops on the conflict
   # edit s2/config.txt, pick the final values
   git add s2/config.txt
   git rebase --continue
   git push --force-with-lease
   ```
5. `gh pr merge --rebase`, then clean up both worktrees.

**Lessons:** `--force-with-lease` refuses to push if the remote branch moved in
a way you haven't seen. Rebasing replays *our* commits on top of *theirs*, so
during the rebase `ours` means upstream and `theirs` means our commit being
replayed. That is the reverse of what you would expect.

---

## Scenario 3: two stacked PRs

**Goal:** build and land `main ← s3-base ← s3-top`.

1. `s3-base` comes off `origin/main` and adds `s3/api.txt`. Open a PR against
   `main`.
2. `s3-top` comes off **`s3-base`**:
   `worktree add --no-track -b s3-top $WT/s3-top s3-base`. It adds
   `s3/client.txt`, which uses the API. Open a PR with `--base s3-base`.
3. Address review feedback on the base: add a commit, or amend, in the `s3-base`
   worktree, then push.
4. Restack the top:
   `git rebase s3-base` from the `s3-top` worktree. If the base was amended,
   use `git rebase --onto s3-base <old-base-tip>` instead. Then
   `push --force-with-lease`.
5. Land the base: `gh pr merge <base-pr> --rebase`. The branch is deleted
   automatically, and **GitHub retargets the top PR to `main`**.
6. The base commits on `main` now have new SHAs, but `s3-top` still contains
   the old ones. Drop them:
   ```sh
   OLD_BASE=$(git rev-parse s3-base)   # local branch still points at the pre-merge tip
   git fetch origin
   git rebase --onto origin/main $OLD_BASE s3-top
   git push --force-with-lease
   ```
   A plain `git rebase origin/main` often works too, because git skips commits
   whose patch is already upstream. `--onto` is the version that always works,
   including when the base was edited during the merge.
7. `gh pr merge <top-pr> --rebase`, then clean up both worktrees.

---

## Scenario 4: a stack while others keep landing changes

**Goal:** keep a 2-branch stack up to date as `main` moves under it, including
a conflict in the base.

1. Build `s4-base ← s4-top` as in scenario 3, with PRs open.
2. A teammate lands an unrelated PR (it touches `s4/other.txt`), then a
   **conflicting** one that touches the same lines as `s4-base`.
3. Restack the whole stack in one go from the top worktree:
   ```sh
   git -C $WT/s4-base switch --detach   # see the worktree gotcha below
   cd $WT/s4-top
   git fetch origin
   git rebase --update-refs origin/main   # moves s4-base along with s4-top
   # resolve the conflict, then: git add …; git rebase --continue
   git push --force-with-lease origin s4-base s4-top
   git -C $WT/s4-base switch s4-base
   ```
4. Land the base, rebase the top `--onto origin/main`, and land the top, as in
   scenario 3.

**Worktree gotcha:** `--update-refs` (and `git branch -f`) will **not** move a
branch that is checked out in another worktree. It is skipped, and the stack
silently ends up half-moved. Detach the lower worktrees first, then switch them
back afterwards.

---

## Scenario 5: reorder a 5-branch stack

**Goal:** `main ← s5-a ← s5-b ← s5-c ← s5-d ← s5-e`, one commit and one PR
each, with chained bases. Move `s5-b` up two positions so the order becomes
**a, c, d, b, e**, and resolve the conflicts this causes.

Setup: everything edits `s5/plan.txt`. `b` rewrites a line, and `c` and `d`
then edit that same line on top of `b`'s version. Moving `b` above them
therefore conflicts both ways.

1. Build the stack: each worktree branches off the previous branch, and each PR
   uses `--base <previous>`.
2. Detach the worktrees for `a`–`d`.
3. From the `s5-e` worktree, run the interactive rebase non-interactively by
   using a script as the sequence editor. The script moves `b`'s `pick` line
   and its `update-ref refs/heads/s5-b` line after `d`'s:
   ```sh
   GIT_SEQUENCE_EDITOR=/path/to/reorder.sh \
     git rebase -i --update-refs origin/main
   ```
   The `update-ref` lines are what move each branch to its new tip. After the
   reorder, `s5-c` sits on `a`, `s5-d` on `c`, `s5-b` on `d`, and `s5-e` on `b`.
4. Resolve each conflict, then `git rebase --continue`.
5. Push every branch: `git push --force-with-lease origin s5-a s5-b s5-c s5-d s5-e`.
6. Fix the PR bases to match the new order:
   `gh pr edit <c> --base s5-a`, `<d> --base s5-c`, `<b> --base s5-d`,
   `<e> --base s5-b`.
7. Switch the worktrees back to their branches. Land the PRs bottom-up,
   restacking with `--onto` after each merge as in scenario 3.
