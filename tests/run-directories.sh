#!/usr/bin/env bash

set -euo pipefail

action_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runner="${action_root}/scripts/run-directories.sh"
fake_cli="${action_root}/tests/fake-ast-metrics.sh"
test_root="$(mktemp -d)"
trap 'rm -rf "${test_root}"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_file_contains() {
    local file="$1"
    local expected="$2"
    grep -Fq -- "${expected}" "${file}" || fail "${file} does not contain '${expected}'"
}

repository="${test_root}/repository"
mkdir -p "${repository}/projects/api" "${repository}/projects/web" "${repository}/bin"
git -C "${repository}" init --quiet --initial-branch=main
git -C "${repository}" config user.name "Test"
git -C "${repository}" config user.email "test@example.com"
printf 'threshold: root\n' > "${repository}/.ast-metrics.yaml"
printf 'threshold: api\n' > "${repository}/projects/api/.ast-metrics.yaml"
printf 'threshold: web\nfail: true\n' > "${repository}/projects/web/.ast-metrics.yaml"
printf 'source\n' > "${repository}/projects/api/source.php"
printf 'source\n' > "${repository}/projects/web/source.php"
git -C "${repository}" add .
git -C "${repository}" commit --quiet -m "initial"
ln -s "${fake_cli}" "${repository}/bin/ast-metrics"

directories_file="${test_root}/directories"
printf 'projects/api\nprojects/web\n' > "${directories_file}"
runner_temp="${test_root}/isolated"
mkdir -p "${runner_temp}"
github_output="${runner_temp}/output"
test_log="${runner_temp}/calls"
: > "${github_output}"
: > "${test_log}"

(
    cd "${repository}"
    PATH="${repository}/bin:${PATH}" \
    AST_METRICS_TEST_LOG="${test_log}" \
    MODE=review \
    ISOLATED=true \
    DIRECTORIES_FILE="${directories_file}" \
    BASE_REF=origin/main \
    FAIL_ON=high \
    MAX_FINDINGS=5 \
    WITH_SARIF=true \
    RUNNER_TEMP="${runner_temp}" \
    GITHUB_OUTPUT="${github_output}" \
    bash "${runner}"
)

assert_file_contains "${test_log}" "${repository}/projects/api|review|.|threshold: api,"
assert_file_contains "${test_log}" "${repository}/projects/web|review|.|threshold: web,fail: true,"
assert_file_contains "${github_output}" "exit-code=1"
assert_file_contains "${runner_temp}/ast-metrics-review.md" '## Project `projects/api`'
assert_file_contains "${runner_temp}/ast-metrics-review.md" '## Project `projects/web`'
jq -e '
    .gate == "failed"
    and (.projects | length == 2)
    and (.summary.filesChanged == 2)
    and (.regressions | length == 1)
' "${runner_temp}/ast-metrics-review.json" > /dev/null || fail "combined review JSON is invalid"
jq -e '.runs | length == 2' "${runner_temp}/ast-metrics-review.sarif" > /dev/null \
    || fail "combined SARIF does not contain both projects"
jq -e '
    [.runs[].automationDetails.id]
    == ["ast-metrics/projects/api", "ast-metrics/projects/web"]
' "${runner_temp}/ast-metrics-review.sarif" > /dev/null \
    || fail "combined SARIF runs do not have stable project identities"

(
    cd "${repository}"
    PATH="${repository}/bin:${PATH}" \
    AST_METRICS_TEST_LOG="${test_log}" \
    MODE=analyze \
    ISOLATED=true \
    DIRECTORIES_FILE="${directories_file}" \
    RUNNER_TEMP="${runner_temp}" \
    bash "${runner}"
)
assert_file_contains "${runner_temp}/ast-metrics-report.md" 'Configuration: threshold: api,'
assert_file_contains "${runner_temp}/ast-metrics-report.md" 'Configuration: threshold: web,fail: true,'
test -f "${runner_temp}/ast-metrics-html-report/projects/api/index.html" \
    || fail "first isolated HTML report is missing"
test -f "${runner_temp}/ast-metrics-html-report/projects/web/index.html" \
    || fail "second isolated HTML report is missing"

html_temp="${test_root}/html"
mkdir -p "${html_temp}"
(
    cd "${repository}"
    PATH="${repository}/bin:${PATH}" \
    AST_METRICS_TEST_LOG="${test_log}" \
    MODE=html \
    ISOLATED=true \
    DIRECTORIES_FILE="${directories_file}" \
    RUNNER_TEMP="${html_temp}" \
    bash "${runner}"
)
test -f "${html_temp}/ast-metrics-html-report/projects/api/index.html" \
    || fail "pull request HTML report is missing"
test -f "${html_temp}/ast-metrics-html-report/projects/web/index.html" \
    || fail "second pull request HTML report is missing"

legacy_directories_file="${test_root}/legacy-directory"
printf 'projects/api\n' > "${legacy_directories_file}"
legacy_temp="${test_root}/legacy"
mkdir -p "${legacy_temp}"
legacy_output="${legacy_temp}/output"
legacy_log="${legacy_temp}/calls"
: > "${legacy_output}"
: > "${legacy_log}"

(
    cd "${repository}"
    PATH="${repository}/bin:${PATH}" \
    AST_METRICS_TEST_LOG="${legacy_log}" \
    MODE=review \
    ISOLATED=false \
    DIRECTORIES_FILE="${legacy_directories_file}" \
    BASE_REF=origin/main \
    WITH_SARIF=false \
    RUNNER_TEMP="${legacy_temp}" \
    GITHUB_OUTPUT="${legacy_output}" \
    bash "${runner}"
)

assert_file_contains "${legacy_log}" "${repository}|review|projects/api|threshold: root,"
jq -e 'has("projects") | not' "${legacy_temp}/ast-metrics-review.json" > /dev/null \
    || fail "legacy JSON report shape changed"

echo "Directory execution tests passed"
