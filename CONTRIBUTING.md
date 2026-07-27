# Contributing

Thanks for helping out. This repository only contains the composite action; the analysis itself lives in [Halleck45/ast-metrics](https://github.com/Halleck45/ast-metrics).

## Layout

- `action.yaml`: the composite action, the only thing consumers use
- `.github/workflows/test.yml`: runs the action on this repository (`uses: ./`) and asserts the reports it produces
- `tests/fixtures/`: sample source files analyzed by that workflow

## Iterating without cutting a release

Consumers reference `@v2`, a moving major tag. Do not move it to try something out. Push a branch instead and point a test workflow at it:

```yaml
- uses: halleck45/action-ast-metrics@my-branch
```

`gh run rerun <run-id>` re-resolves the branch to its new tip, so pushing to the branch and rerunning is the fastest loop.

Locally, [`act`](https://github.com/nektos/act) can substitute a checkout of this repository for the published action:

```bash
act pull_request --eventpath ./event.json \
  --local-repository halleck45/action-ast-metrics@v2=/path/to/action-ast-metrics
```

The SARIF upload step fails under `act` (no code scanning API); it is `continue-on-error`, so the rest of the run still completes.

## Testing an unreleased AST Metrics build

By default the action downloads a released binary, so an unreleased CLI feature cannot be exercised. Set `version: local` to reuse whatever `ast-metrics` a previous step put in the `PATH`:

```yaml
- name: Build AST Metrics from source
  run: |
    git clone --depth 1 https://github.com/Halleck45/ast-metrics /tmp/ast-metrics
    make -C /tmp/ast-metrics build
    sudo install /tmp/ast-metrics/bin/ast-metrics /usr/local/bin/ast-metrics
- uses: halleck45/action-ast-metrics@v2
  with:
    version: local
```

Pin `version:` in test workflows otherwise: the `latest` default queries `api.github.com` without a token and can hit the rate limit.

## Releasing

1. Release AST Metrics first if the action relies on a new CLI flag; the install step downloads a published binary.
2. Create the GitHub release for this repository, which tags `vX.Y.Z`.
3. Move the moving major tag by hand, the release does not do it:

```bash
git tag -f v2 && git push -f origin v2
```
