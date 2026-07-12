# Contributing to Fullsend

Thank you for your interest in contributing! This document covers the social norms and processes we follow.

## First-Time Contributors

This project uses a **vouch system**. AI tools make it trivial to generate plausible-looking but low-quality contributions, so we require first-time contributors to be vouched by a maintainer before submitting pull requests.

1. Open a [Vouch Request](https://github.com/fullsend-ai/fullsend/discussions/new?category=vouch-request) discussion on the main fullsend repo.
2. Describe what you want to change and why.
3. Write in your own words — do not have an AI generate the request. Requests that read like LLM output will be denied.
4. A maintainer will comment `/vouch` if approved.
5. Once vouched, you can submit pull requests to any repo in the fullsend-ai org.

**If you are not vouched, any pull request you open will be automatically closed.** Org members and collaborators with write access bypass this check.

## Commit messages

This project uses [Conventional Commits](https://www.conventionalcommits.org/). See [COMMITS.md](COMMITS.md) for the full specification, type selection rules, and examples.

## DCO (Developer Certificate of Origin)

This project uses the [Probot DCO app](https://github.com/apps/dco) to enforce sign-off on commits. Add `Signed-off-by` to your commits with `git commit -s`.

**Human-driven agent sessions** (e.g., using Claude Code locally) should sign off — the human directing the session is the one certifying the DCO, just as they would for any other commit.

**Autonomous agent commits are exempt.** The fullsend agents run without a human in the loop at commit time. The DCO is a human attestation — it certifies personhood and legal authority to contribute. No one is present to make that certification in an autonomous session. These agents commit using the GitHub App's bot identity (`<id>+<slug>[bot]@users.noreply.github.com`), which GitHub recognizes as `author.type: "Bot"`. The Probot DCO app auto-skips bot-authored commits. The human who merges an agent PR accepts responsibility for the contribution.

## Pull request workflow

### Opening a PR

- Stage your changes and fix any lint failures before pushing.
- Keep PRs focused. One problem area or decision per PR is easier to review than a grab-bag.
- **If your PR introduces a breaking change**, the PR title must carry the `!` suffix (e.g., `feat(harness)!: require role field`). See [COMMITS.md](COMMITS.md#breaking-changes) for how to identify breaking changes and what to include in the commit body.

### Review etiquette

- **Comment resolution belongs to the PR author.** When a reviewer leaves a comment, the PR author is free to address the feedback and resolve the conversation themselves. This keeps the review cycle moving.
- **If you need to block a PR on your feedback, use "Request changes."** A comment alone is advisory — the author may resolve it at their discretion. The "Request changes" review status is how a reviewer signals that the PR should not merge until their concern is addressed. This is the only mechanism for enforcing your review.
- **Be constructive.** Disagreement is expected and valuable. Critique ideas, not people. When you push back on a proposal, suggest an alternative or explain what concern drives your objection.

### Reworking a PR

When a PR needs a significant change in approach — not just addressing review feedback, but rethinking the implementation or design — close the existing PR with a comment explaining why, and open a new one. Link the new PR to the old one for historical continuity. This is preferred over force-pushing because:

- Reviewers see a fresh PR in their queue instead of missing that the content changed completely.
- The closed PR preserves the original discussion and the reasoning behind the pivot.
- Metrics can track rework cycles accurately.

Small adjustments in response to review feedback are normal iteration — this guideline applies when the underlying approach changes.

### Merging

- PRs require approval from a maintainer before merging.

## License

All contributions to this project are made under the [Apache License, Version 2.0](LICENSE). By submitting a pull request, you agree that your contributions will be licensed under this license.
