# Development evaluations

The evaluations under `eval/dev/` are for fullsend agent developers who want
to assess the impact of a change: a new instruction set, a different model or
runtime, a reworked skill. They run live models against realistic work and
grade the result with model judges, so a single run costs tens of dollars and
takes an hour or more per arm.

For that reason they are **not part of CI**. The functional-test workflow
enumerates `eval/*/eval.yaml` (one directory level) and never sees this
directory; nothing here gates a pull request, the merge queue, a release or
the nightly run. Run them on demand:

```bash
EVAL_ORG=<github-user-or-org> ./eval/run-functional.sh dev/<name>
```

The runner treats `dev/<name>` like any other eval name: the config is
`eval/dev/<name>/eval.yaml`, cases are `eval/dev/<name>/cases/`, and results
land under `eval/runs/<name>/` (the eval keeps its own name as `execution.skill`). Comparisons across arms or repeated
samples use the harness's `eval-anova` and `eval-compare` skills.

| Eval | Measures | Notes |
|---|---|---|
| [`code-rhai`](code-rhai/) | the code agent on feature-scale epics, graded without reference solutions | one arm per coder model (`matrix.factors.model`); see its README for the design and the case recipe |

Adding one: create `eval/dev/<name>/` with an `eval.yaml` and `cases/`, add a
row here, and keep anything expensive or slow out of `eval/<agent>/`, which CI
does run.
