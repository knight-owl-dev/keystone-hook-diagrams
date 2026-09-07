# GitHub Issue Creation Command

Create a new GitHub issue following project templates.

## Arguments: $ARGUMENTS

## Instructions

### 1. Gather Issue Description

**If arguments are provided**: Use `$ARGUMENTS` as the issue description.

**If arguments are empty**: Ask the user to describe the issue using AskUserQuestion:

- Question: "What would you like to create an issue for?"
- Header: "Description"
- Options: Provide 2-3 example categories as options (e.g., "Bug report", "New feature",
  "Documentation update") but allow free-form input via "Other"

### 2. Determine Issue Type

The organization defines three issue types. Pick one — step 8 sets it at
creation, and it is distinct from the labels in step 3.

| Type      | When to pick it                                                  |
|-----------|------------------------------------------------------------------|
| `Bug`     | Broken, failing, or unexpected behavior — including a regression |
| `Feature` | New functionality an author or forker would notice and use       |
| `Task`    | Everything else — internal work, docs, CI, refactors, gates      |

`Feature` is narrower than it reads, and `Task` is the common case: work on the
hook's own plumbing is a `Task` even when it carries the `enhancement` label.
The type answers *what kind of work is this*; the label answers *what does it
touch*.

### 3. Suggest Labels

Based on the description, recommend applicable labels from this list:

| Label              | When to suggest                                |
|--------------------|------------------------------------------------|
| `bug`              | Something is broken or not working as expected |
| `enhancement`      | New feature, improvement, or planned work      |
| `documentation`    | Documentation-only changes                     |
| `security`         | Security-related fixes or improvements         |
| `breaking-change`  | Changes that break existing behavior           |
| `dependencies`     | Dependency updates                             |
| `docker`           | Dockerfile or base image changes               |
| `renderer`         | mermaid / puppeteer-core / Chromium changes    |
| `good-first-issue` | Simple issues suitable for newcomers           |
| `help-wanted`      | Issues needing extra attention or expertise    |

Always suggest at least one primary label (`bug`, `enhancement`, or `documentation`).

### 4. Confirm with User

Use AskUserQuestion to confirm the issue type and labels:

- Show the determined issue type (`Task`, `Bug` or `Feature`)
- Show the recommended labels
- Allow the user to adjust before proceeding

### 5. Draft Issue Content

Based on the confirmed type, draft the issue following the appropriate template.

**Formatting**: Write paragraphs as flowing text without hard line breaks. GitHub's
markdown renderer handles wrapping automatically. Only use line breaks between sections
or for bullet lists. Keep it laconic and load-bearing — state the goal and scope,
nothing more; cut flourish and drama.

**For Bug Reports** (template: `.github/ISSUE_TEMPLATE/bug.md`):

```markdown
## What happened

[Extract from description: the observed behavior]

## What was expected

[Infer or ask: what should have happened]

## Steps to reproduce

[If provided, otherwise mark as "To be determined"]

## Environment

[If provided, otherwise mark as "To be determined"]

## Notes

[Any additional context from the description]
```

**For Features and Tasks** (template: `.github/ISSUE_TEMPLATE/task.md`):

```markdown
## Goal

[Extract from description: the outcome being achieved]

## Scope

- [Break down into high-level bullets]
- [Focus on what is included]
- [Avoid implementation details]

## Outcome

[What will be improved, clearer, safer, faster, or more reliable]

## Notes

[Any additional context, constraints, or links]
```

### 6. Generate Issue Title

Create a clear, concise title that:

- Is outcome-focused (describes what will be achieved or fixed)
- Uses imperative mood for tasks ("Add...", "Enable...", "Update...")
- Uses descriptive mood for bugs ("Fix...", "Resolve...")
- Is 50-72 characters when possible

### 7. Preview and Confirm

Show the user a preview of:

- Title
- Labels
- Body content

Ask for confirmation before creating.

### 8. Create the Issue

Use the gh CLI to create the issue:

Use a separate `--label` flag for each label.

```bash
gh issue create \
  --repo knight-owl-dev/keystone-hook-diagrams \
  --type "<type>" \
  --label "<label-1>" \
  --label "<label-2>" \
  --title "<title>" \
  --body "<body>"
```

### 9. Output

After successful creation:

- Display the issue URL
- Offer to create a branch for the issue (using GitHub's naming convention:
  `<issue-number>-<issue-title-slug>`)
