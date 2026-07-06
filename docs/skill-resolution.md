# Skill resolution

## Extension point skills

Some skills declared in agent frontmatter are **extension points** —
intentionally absent from this repo and expected to be provided by
target repos or org-level configuration. When declaring one, annotate
the reference with an inline YAML comment so the intent is discoverable
at the point of contact:

```yaml
skills:
  - customer-research  # extension point: provided by target repos
```

Without the annotation, agents and reviewers may treat the missing
skill directory as a bug and file issues or PRs to add it (see the
PR #12 to #21 cycle for an example of this false-positive pattern).
