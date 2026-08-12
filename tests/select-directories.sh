#!/usr/bin/env bash

set -euo pipefail

action_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
selector="${action_root}/scripts/select-directories.sh"
test_root="$(mktemp -d)"
trap 'rm -rf "${test_root}"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    [ "${actual}" = "${expected}" ] || fail "expected '${expected}', got '${actual}'"
}

output_value() {
    local output_file="$1"
    local name="$2"
    sed -n "s/^${name}=//p" "${output_file}"
}

new_repository() {
    local repository="$1"
    mkdir -p "${repository}/apps/api" "${repository}/apps/web" "${repository}/docs" "${repository}/packages/with space"
    git -C "${repository}" init --quiet --initial-branch=main
    git -C "${repository}" config user.name "Test"
    git -C "${repository}" config user.email "test@example.com"
    printf 'api\n' > "${repository}/apps/api/source.php"
    printf 'web\n' > "${repository}/apps/web/source.php"
    printf 'docs\n' > "${repository}/docs/readme.md"
    printf 'space\n' > "${repository}/packages/with space/source.php"
    git -C "${repository}" add .
    git -C "${repository}" commit --quiet -m "initial"
    git -C "${repository}" switch --quiet -c feature
    git -C "${repository}" update-ref refs/remotes/origin/main refs/heads/main
}

run_selector() {
    local repository="$1"
    local directories="$2"
    local only_changed="$3"
    local event_name="${4:-pull_request}"
    local directory="${5:-.}"
    local runner_temp="${repository}/runner-temp"
    mkdir -p "${runner_temp}"
    local output_file="${runner_temp}/output"
    : > "${output_file}"

    (
        cd "${repository}"
        DIRECTORY="${directory}" \
        DIRECTORIES="${directories}" \
        ONLY_CHANGED="${only_changed}" \
        EVENT_NAME="${event_name}" \
        BASE_REF="main" \
        RUNNER_TEMP="${runner_temp}" \
        GITHUB_OUTPUT="${output_file}" \
        bash "${selector}" >&2
    ) || return $?

    printf '%s' "${output_file}"
}

repository="${test_root}/changed"
new_repository "${repository}"
printf 'change\n' >> "${repository}/apps/api/source.php"
git -C "${repository}" add .
git -C "${repository}" commit --quiet -m "change api"
output_file="$(run_selector "${repository}" $'apps/api\napps/web\npackages/with space' true)"
assert_equals "true" "$(output_value "${output_file}" has-directories)"
assert_equals "origin/main" "$(output_value "${output_file}" base-ref)"
assert_equals "true" "$(output_value "${output_file}" isolated)"
assert_equals "apps/api" "$(cat "$(output_value "${output_file}" directories-file)")"

repository="${test_root}/outside"
new_repository "${repository}"
printf 'change\n' >> "${repository}/docs/readme.md"
git -C "${repository}" add .
git -C "${repository}" commit --quiet -m "change docs"
output_file="$(run_selector "${repository}" $'apps/api\napps/web' true)"
assert_equals "false" "$(output_value "${output_file}" has-directories)"
assert_equals "" "$(cat "$(output_value "${output_file}" directories-file)")"

output_file="$(run_selector "${repository}" $'apps/api\napps/web' '')"
assert_equals "false" "$(output_value "${output_file}" has-directories)"
assert_equals "" "$(cat "$(output_value "${output_file}" directories-file)")"

output_file="$(run_selector "${repository}" '' true pull_request docs)"
assert_equals "false" "$(output_value "${output_file}" isolated)"
assert_equals "docs" "$(cat "$(output_value "${output_file}" directories-file)")"

output_file="$(run_selector "${repository}" $'apps/api\napps/web' false)"
assert_equals $'apps/api\napps/web' "$(cat "$(output_value "${output_file}" directories-file)")"

repository="${test_root}/configuration"
new_repository "${repository}"
printf 'requirements: {}\n' > "${repository}/.ast-metrics.yaml"
git -C "${repository}" add .
git -C "${repository}" commit --quiet -m "change configuration"
output_file="$(run_selector "${repository}" $'apps/api\napps/web' true)"
assert_equals "false" "$(output_value "${output_file}" has-directories)"

repository="${test_root}/project-configuration"
new_repository "${repository}"
printf 'requirements: {}\n' > "${repository}/apps/api/.ast-metrics.yaml"
git -C "${repository}" add .
git -C "${repository}" commit --quiet -m "change project configuration"
output_file="$(run_selector "${repository}" $'apps/api\napps/web' true)"
assert_equals "apps/api" "$(cat "$(output_value "${output_file}" directories-file)")"

repository="${test_root}/renamed"
new_repository "${repository}"
git -C "${repository}" mv "apps/api/source.php" "apps/web/moved.php"
git -C "${repository}" commit --quiet -m "move source"
output_file="$(run_selector "${repository}" $'apps/api\napps/web' true)"
assert_equals $'apps/api\napps/web' "$(cat "$(output_value "${output_file}" directories-file)")"

repository="${test_root}/deleted"
new_repository "${repository}"
git -C "${repository}" rm --quiet "apps/api/source.php"
git -C "${repository}" commit --quiet -m "delete api"
output_file="$(run_selector "${repository}" 'apps/api' true)"
assert_equals "false" "$(output_value "${output_file}" has-directories)"

repository="${test_root}/push"
new_repository "${repository}"
output_file="$(run_selector "${repository}" $'apps/api\npackages/with space' true push)"
assert_equals $'apps/api\npackages/with space' "$(cat "$(output_value "${output_file}" directories-file)")"

repository="${test_root}/invalid"
new_repository "${repository}"
if run_selector "${repository}" $'apps\napps/api' true > /dev/null 2>&1; then
    fail "overlapping directories should be rejected"
fi
if run_selector "${repository}" '../outside' true > /dev/null 2>&1; then
    fail "directories outside the repository should be rejected"
fi

echo "Directory selection tests passed"
