# AST Metrics GitHub Action

> Prevent architectural regressions in your pull requests, powered by [AST Metrics](https://github.com/Halleck45/ast-metrics/).

On each pull request, this action compares your branch with the target branch and reports **only new or worsened issues**: existing debt is never reported. Typical findings:

- a method that became too complex;
- a strong maintainability drop on modified code;
- a significant coupling increase on a modified file;
- new violations of your configured architecture rules (e.g. forbidden dependencies);
- notable improvements, so the report is not only negative.

On `push` events, the action runs a full analysis and publishes the report in the job summary, with the HTML report as an artifact (same behavior as v1).

Analysis runs entirely on the runner: no account, no code sent anywhere.

## Usage

Create `.github/workflows/ast-metrics.yml`:

```yaml
name: AST Metrics
on:
  pull_request:

permissions:
  contents: read
  pull-requests: write   # optional: allows the action to comment on the pull request

jobs:
  ast-metrics:
    runs-on: ubuntu-latest
    steps:
      - uses: halleck45/action-ast-metrics@v2
```

That's it. Each pull request gets a check with a short, stable summary:

```text
AST Metrics: quality gate passed

3 file(s) changed, 0 new critical issue(s), 2 other regression(s)

Regressions:
- [MEDIUM] CheckoutService::pay (src/Checkout/CheckoutService.php:42)
      Cyclomatic complexity: 8 -> 15 (threshold: 10)
      Suggested action: Extract smaller, well-named functions to reduce decision points

Existing debt is not reported. Methodology v1.0
```

## Permissions

The action degrades gracefully depending on the permissions you grant:

| Feature | Required permission | Behavior when missing |
|---|---|---|
| Check status and job summary | none | always works, including pull requests from forks |
| Inline annotations (`annotations`) | none | always works, including pull requests from forks |
| Pull request comment | `pull-requests: write` | skipped with a notice; the report stays in the job summary |
| SARIF upload (`sarif: true`) | `security-events: write` (and GitHub Advanced Security on private repositories) | skipped without failing the build |

Note: pull requests coming from forks always run with a read-only token; the comment is skipped and the job summary is used instead.

## Inputs

| Input | Default | Description |
|---|---|---|
| `version` | `latest` | AST Metrics version to install. Pinning (e.g. `v0.28.0`) is recommended for reproducible checks. `local` reuses an `ast-metrics` binary already present in the `PATH` instead of downloading a release. |
| `directory` | `.` | Directory to analyze. |
| `base` | base branch of the PR | Git reference to compare with. |
| `fail-on` | `never` | Fail the check when a regression of at least this severity is introduced: `high`, `medium`, `any` or `never`. |
| `comment` | `true` | Post and update a single comment on the pull request (best effort). |
| `annotations` | `auto` | Annotate the changed files with the new findings, directly from the workflow (no GitHub Advanced Security required). `auto` enables them unless `sarif` is enabled, since code scanning already annotates the same findings. `true` forces both channels, `false` disables them. |
| `sarif` | `false` | Upload regressions to GitHub code scanning. Alerts are reported by the GitHub Advanced Security bot under the Security tab; use `annotations` for plain quality annotations. |
| `sarif-max-level` | `warning` | Ceiling for the level of the SARIF results: `error`, `warning` or `note`. Code scanning fails its own check as soon as a new `error` alert appears in the diff, so the default keeps it informative like `fail-on: never`. Set to `error` to let code scanning block the pull request. |
| `html-artifact` | `auto` | Upload the full HTML report as an artifact: `true` on push, `false` on pull requests by default. |
| `max-findings` | `5` | Maximum number of regressions displayed in the summary and the comment. |

### Blocking mode

Start in informative mode (the default), then make the gate blocking once the team trusts the signal:

```yaml
- uses: halleck45/action-ast-metrics@v2
  with:
    fail-on: high
```

`fail-on` is the only gate, including with `sarif: true`. Code scanning publishes a check of its own and fails it on any new `error` level alert, whatever `fail-on` says, so the action caps the SARIF level at `warning` by default (see `sarif-max-level`) to keep that check informative. Set `sarif-max-level: error` if you do want code scanning to block as well.

### Architecture rules

If your repository has an `.ast-metrics.yaml` configuration with requirements (forbidden dependencies, complexity budgets...), the review also reports **new** violations introduced by the pull request, and only those.

## Migrating from v1

- The `push` behavior is unchanged (full analysis, job summary, HTML artifact).
- `report_html_directory` and `report_markdown_filename` inputs were removed; reports are now written to the runner temporary directory and published as summary or artifact.
- New pull request mode: add `pull_request:` to your workflow triggers to enable it.

## License

MIT. See [LICENSE](LICENSE) for more details.
