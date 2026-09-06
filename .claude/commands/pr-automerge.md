# PR Auto-Merge Command

Enable auto-merge (squash) on a pull request with a reviewed, consolidated commit
body — and **no subject**, so GitHub keeps the PR title as the squash title and
appends `(#N)` on merge.

## Arguments: $ARGUMENTS

Optional PR number or URL. If omitted, target the PR for the current branch.

## Instructions

### 1. Resolve the PR

If an argument is given, use it. Otherwise find the PR for the current branch:

```bash
gh pr view --json number,title,state,isDraft,mergeable,headRefName,url,body
```

If no PR exists for the branch, stop and tell the user (suggest `/pr-create`).

### 2. Check preconditions

- **Open, not draft** — if `state != OPEN` or `isDraft`, stop.
- **Mergeable** — if `mergeable == CONFLICTING`, stop and report the conflict.
- **Checks** — read the rollup for context:

  ```bash
  gh pr checks <number> 2>/dev/null || true
  ```

  Auto-merge waits for required checks, so PENDING is fine — note it, do not
  block. Warn (do not hard-stop) if a check has already FAILED: auto-merge will
  never complete until it is fixed.

- **Unresolved review threads** — this repo blocks auto-merge until every review
  thread is resolved (Copilot's reviewer opens threads that must be marked
  resolved once addressed; otherwise `--auto` never completes even on green).
  List them:

  ```bash
  gh api graphql -f query='query{repository(owner:"knight-owl-dev",name:"keystone-hook-diagrams"){pullRequest(number:'"<number>"'){reviewThreads(first:100){nodes{id isResolved comments(first:1){nodes{author{login} path line body}}}}}}}' \
    --jq '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved|not)'
  ```

  For each unresolved thread whose feedback is **already addressed**, resolve it:

  ```bash
  gh api graphql -f query='mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{isResolved}}}' -f id=<threadId>
  ```

  Never resolve a thread whose feedback is not yet handled — fix it first, then
  resolve. If any unresolved thread is unaddressed, stop and tell the user.

### 3. Generate the consolidated squash body

Distill the PR's commits and description into one clean, changelog-style body —
the change and why, grouped conceptually, not a commit-by-commit dump:

```bash
git log main..HEAD --format='%s%n%b'
```

- **No subject line in the body.** GitHub uses the PR title as the squash title
  and appends `(#N)` on merge — do not restate it here.
- Laconic and load-bearing; flowing prose or tight bullets, no drama.
- Keep it consistent with the PR's own Summary/Changes.

### 4. Let the user review the body

Show the generated body verbatim, then AskUserQuestion:

- Question: "Enable auto-merge with this body?"
- Options: "Enable as shown", "Edit the body", "Cancel".

If "Edit", take the revision and re-confirm before proceeding.

### 5. Enable auto-merge

```bash
gh pr merge <number> --auto --squash --body "<approved body>"
```

Omit `--subject` deliberately: GitHub defaults the squash title to the PR title
and appends `(#N)`. Passing a subject would override that and drop the PR-number
suffix.

### 6. Confirm

Report that auto-merge is enabled and the PR will squash-merge once required
checks pass. Show the PR URL.

### Error Handling

- **No PR for the branch** — suggest `/pr-create`.
- **Auto-merge disabled on the repo** — `gh` errors; tell the user to enable it
  (Settings → General → Allow auto-merge) or merge manually.
- **Already enabled** — report it; re-running with a new `--body` updates the
  pending squash body.
