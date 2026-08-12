# AST Metrics GitHub Action

> Prevent architectural regressions in your pull requests, powered by [AST Metrics](https://github.com/ast-metrics/ast-metrics/).

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
      - uses: ast-metrics/action-ast-metrics@v2
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
| `directory` | `.` | Directory to analyze. Kept for backward compatibility; ignored when `directories` is set. |
| `directories` | empty | Independent project directories to analyze, one per line. Each project uses its local AST Metrics configuration. |
| `only-changed` | `true` | On pull requests, analyze only configured directories containing changed files. Set it to `false` to analyze every configured directory. |
| `base` | base branch of the PR | Git reference to compare with. |
| `fail-on` | `never` | Fail the check when a regression of at least this severity is introduced: `high`, `medium`, `any` or `never`. |
| `comment` | `true` | Post and update a single comment on the pull request (best effort). |
| `annotations` | `auto` | Annotate the changed files with the new findings, directly from the workflow (no GitHub Advanced Security required). `auto` enables them unless `sarif` is enabled, since code scanning already annotates the same findings. `true` forces both channels, `false` disables them. |
| `sarif` | `false` | Upload regressions to GitHub code scanning. Alerts are reported by the GitHub Advanced Security bot under the Security tab; use `annotations` for plain quality annotations. |
| `sarif-max-level` | `warning` | Ceiling for the level of the SARIF results: `error`, `warning` or `note`. Code scanning fails its own check as soon as a new `error` alert appears in the diff, so the default keeps it informative like `fail-on: never`. Set to `error` to let code scanning block the pull request. |
| `html-artifact` | `auto` | Upload the full HTML report as an artifact: `true` on push, `false` on pull requests by default. |
| `max-findings` | `5` | Maximum number of regressions displayed per project in the summary and the comment. |

### Monorepositories

List each project once, one directory per line:

```yaml
- uses: ast-metrics/action-ast-metrics@v2
  with:
    directories: |
      apps/api
      apps/backoffice
      packages/shared
```

Each directory is treated as an independent project. AST Metrics runs once per directory, from that directory, so files such as `apps/api/.ast-metrics.yaml` and `apps/backoffice/.ast-metrics.yaml` can define different exclusions, requirements, and thresholds.

The action consolidates the per-project Markdown reports into one job summary and pull request comment. It also combines annotations and SARIF results, places every HTML report under its project path in the same artifact, and fails the global quality gate when any project fails its own gate.

By default, a directory is analyzed only when at least one changed path is inside it. This avoids running AST Metrics for projects outside the scope of the pull request.

Set `only-changed: false` to analyze every configured directory on each pull request:

```yaml
with:
  directories: |
    apps/api
    apps/backoffice
  only-changed: false
```

The comparison uses the PR merge-base and handles spaces, renames, and deletions without calling the GitHub API. If no directory requires analysis, installation and analysis are skipped and the check succeeds with an explicit summary. Pushes still analyze every configured directory.

Changing a project's local AST Metrics configuration selects that project because the configuration lives inside its directory. Pushes always analyze every configured directory, regardless of this input.

Configured directories must be inside the checkout and must not overlap, which prevents duplicate findings across project reports. Missing paths are rejected, except for a directory deleted by the current pull request.

The legacy `directory` input keeps its original behavior: AST Metrics runs from the repository root and loads the root configuration. Use `directories` when each monorepo project owns its configuration.

### Blocking mode

Start in informative mode (the default), then make the gate blocking once the team trusts the signal:

```yaml
- uses: ast-metrics/action-ast-metrics@v2
  with:
    fail-on: high
```

### Architecture rules

If your repository has an `.ast-metrics.yaml` configuration with requirements (forbidden dependencies, complexity budgets...), the review also reports **new** violations introduced by the pull request, and only those.

## Migrating from v1

- The `push` behavior is unchanged (full analysis, job summary, HTML artifact).
- `report_html_directory` and `report_markdown_filename` inputs were removed; reports are now written to the runner temporary directory and published as summary or artifact.
- New pull request mode: add `pull_request:` to your workflow triggers to enable it.

## License

MIT. See [LICENSE](LICENSE) for more details.
