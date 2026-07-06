# Commit Messages

This project uses [Conventional Commits](https://www.conventionalcommits.org/). Every commit on `main` should use the correct prefix so that commit history stays meaningful. You **must** consult this file when writing or reviewing commit messages.

## Format

```
<type>(<scope>): <short description>

<optional body>

<optional trailers>
```

## Types

| Type | Purpose |
|---|---|
| `feat` | New user-facing functionality |
| `fix` | Bug fix visible to users |
| `refactor` | Code restructuring (no behavior change) |
| `docs` | Documentation only |
| `test` | Adding or updating tests |
| `chore` | Maintenance (CI, deps, tooling) |
| `ci` | CI/CD pipeline changes |
| `perf` | Performance improvement |
| `build` | Build system or dependency changes |

## `feat` is for end users

Reserve `feat` for changes an end user would recognize as new capability:

- A new agent behavior they interact with
- A new workflow or integration they can target
- A new customization they can configure

**`feat` is wrong for:**

- Restructuring internals (extracting a sub-agent, splitting a package) → `refactor`
- Adding internal helpers or abstractions that don't change user-visible behavior → `refactor`
- Upgrading a dependency or vendored tool version → `chore`
- Tightening internal heuristics, adjusting prompts, or tuning agent behavior that users don't directly control → `refactor` or `fix` depending on whether it corrects a defect
- Addressing review feedback on an existing PR → `fix` or `refactor`, not `feat`

Apply the same discipline to `fix` — bumping a dependency version is `chore`, not `fix`, unless it corrects a user-visible bug. Removing a trailing blank line is `chore`, not `fix`.

**When in doubt, prefer `refactor` or `chore` over `feat` or `fix`.** A change miscategorized as `refactor` is harmless. A change miscategorized as `feat` erodes the signal of the commit history.

## Scope

The parenthesized scope is optional but encouraged. Use it to identify the subsystem: `feat(harness)`, `fix(dispatch)`, `docs(agents)`, `chore(ci)`. When fixing a specific issue, prefer the issue number as scope: `fix(#123): ...`.

### Forbidden type + scope combinations

Some type/scope pairs are misleading. These combinations put infrastructure changes in user-facing categories.

| Forbidden | Why | Use instead |
|---|---|---|
| `fix(ci)` | CI changes are not user-visible bug fixes | `ci(<subsystem>)` |
| `feat(ci)` | CI changes are not user-visible features | `ci(<subsystem>)` |
| `fix(e2e)` | E2E test changes are not user-visible bug fixes | `ci(e2e)` |
| `feat(e2e)` | E2E test changes are not user-visible features | `ci(e2e)` |

## Breaking changes

Breaking changes **must** be marked in both commit messages and PR titles.

**How to mark a breaking change:**

1. Append `!` after the type/scope: `feat(harness)!: require role field`
2. Include a `BREAKING CHANGE:` trailer in the commit body explaining what breaks and how to migrate

Both the `!` suffix and the trailer are required. The `!` suffix signals the breaking change to human reviewers; the trailer tells users what to do about it.

**How to tell if your change is breaking:**

- A previously optional field, flag, or input is now required
- A field, flag, command, or API endpoint is removed or renamed
- Default values change in ways that alter existing behavior
- Validation is added that rejects previously accepted input
- Output format changes that downstream consumers parse

If you are unsure whether a change is breaking, mark it. A false positive is far less costly than a silent break.

**Example** (full commit message):

```
feat(harness)!: require role field in harness YAML

Harness files without a role: field now fail validation.

BREAKING CHANGE: Add `role: <rolename>` to any harness file that
lacks it.
```

## Examples

```
feat(triage): add priority label output to post-triage script

fix(#42): correct dispatch event payload for review agent

refactor(harness): consolidate review harness overrides

chore(ci): bump fullsend action version

docs: add agent definition authoring guide
```

## Reviewing commit messages and PR titles

When reviewing PRs, check that commit messages and PR titles use the correct type prefix. Flag violations as a required change — they are not cosmetic. Pay particular attention to:

- **`feat` misuse** — challenge it if the change is not user-facing.
- **Missing `!` on breaking changes** — if the diff removes a field, renames a flag, adds a required input, tightens validation, or otherwise breaks existing usage, the PR title and commit messages **must** carry the `!` suffix. Flag a missing `!` as an important-severity finding.
