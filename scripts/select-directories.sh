#!/usr/bin/env bash

set -euo pipefail

: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

DIRECTORY="${DIRECTORY:-.}"
DIRECTORIES="${DIRECTORIES:-}"
ONLY_CHANGED="${ONLY_CHANGED:-true}"
EVENT_NAME="${EVENT_NAME:-}"
BASE_REF="${BASE_REF:-}"
BEFORE_SHA="${BEFORE_SHA:-}"

case "${ONLY_CHANGED}" in
    true|false) ;;
    *)
        echo "::error::only-changed must be either 'true' or 'false'"
        exit 1
        ;;
esac

# Normalized the same way as the configured directories below, so the
# containment check always compares two resolved paths.
repository_root="$(realpath -- "$(git rev-parse --show-toplevel)")"
selected_file="${RUNNER_TEMP}/ast-metrics-directories"
: > "${selected_file}"

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "${value}"
}

# True when the second directory is inside the first one. '.' is the repository
# root, so it contains every other directory.
contains_directory() {
    local container="$1"
    local candidate="$2"
    [ "${container}" = "." ] && return 0
    case "${candidate}/" in
        "${container}"/*) return 0 ;;
    esac
    return 1
}

declare -a requested=()
if [ -n "${DIRECTORIES}" ]; then
    isolated=true
    while IFS= read -r line || [ -n "${line}" ]; do
        line="$(trim "${line%$'\r'}")"
        [ -n "${line}" ] && requested+=("${line}")
    done <<< "${DIRECTORIES}"
else
    isolated=false
    requested+=("${DIRECTORY}")
fi

if [ "${#requested[@]}" -eq 0 ]; then
    echo "::error::directories must contain at least one directory"
    exit 1
fi

declare -a configured=()
for requested_path in "${requested[@]}"; do
    absolute_path="$(realpath -m -- "${requested_path}")"
    case "${absolute_path}/" in
        "${repository_root}/"*) ;;
        *)
            echo "::error::Directory '${requested_path}' is outside the checked-out repository"
            exit 1
            ;;
    esac

    # Both paths are already canonical, so stripping the prefix is enough. A
    # second realpath call would not be: it requires every component but the
    # last to exist, and deleting the last project under a parent directory
    # takes that parent away too.
    relative_path="${absolute_path#"${repository_root}"}"
    relative_path="${relative_path#/}"
    [ -z "${relative_path}" ] && relative_path="."

    for existing_path in "${configured[@]}"; do
        if [ "${relative_path}" = "${existing_path}" ]; then
            echo "::error::Directory '${requested_path}' is configured more than once"
            exit 1
        fi
        if contains_directory "${existing_path}" "${relative_path}" \
            || contains_directory "${relative_path}" "${existing_path}"; then
            echo "::error::Directory '${relative_path}' overlaps configured directory '${existing_path}'"
            exit 1
        fi
    done
    configured+=("${relative_path}")
done

resolved_base_ref=""
comparison_point=""
if [ "${EVENT_NAME}" = "pull_request" ]; then
    if [ -z "${BASE_REF}" ]; then
        echo "::error::A base Git reference is required for pull request analysis"
        exit 1
    fi

    declare -a base_candidates=()
    case "${BASE_REF}" in
        origin/*|refs/*) base_candidates+=("${BASE_REF}") ;;
        *) base_candidates+=("origin/${BASE_REF}" "${BASE_REF}") ;;
    esac

    for candidate in "${base_candidates[@]}"; do
        if git rev-parse --verify --quiet "${candidate}^{commit}" > /dev/null; then
            resolved_base_ref="${candidate}"
            break
        fi
    done
    if [ -z "${resolved_base_ref}" ]; then
        echo "::error::Cannot resolve base '${BASE_REF}'; make sure it was fetched"
        exit 1
    fi

    base_sha="$(git rev-parse "${resolved_base_ref}^{commit}")"
    comparison_point="$(git merge-base "${base_sha}" HEAD 2>/dev/null || printf '%s' "${base_sha}")"
elif [ -n "${BEFORE_SHA}" ] && git rev-parse --verify --quiet "${BEFORE_SHA}^{commit}" > /dev/null; then
    # Previous tip of the branch. It only serves the deleted directory check
    # below: a push analyzes every configured directory anyway. Absent for a
    # freshly created branch, where the payload carries a null SHA.
    comparison_point="${BEFORE_SHA}"
fi

declare -a available=()
for relative_path in "${configured[@]}"; do
    absolute_path="${repository_root}/${relative_path}"
    if [ -d "${absolute_path}" ]; then
        available+=("${relative_path}")
        continue
    fi

    # A directory the analyzed change itself deleted is skipped rather than
    # fatal, so that the same change does not have to land together with the
    # workflow update. Once it is gone from the comparison point too, the
    # configuration is stale and staying silent would hide the missing analysis.
    if [ -n "${comparison_point}" ] \
        && [ "$(git cat-file -t "${comparison_point}:${relative_path}" 2>/dev/null || true)" = "tree" ]; then
        echo "::warning::Directory '${relative_path}' was deleted; remove it from the directories input"
        continue
    fi

    echo "::error::Configured directory '${relative_path}' does not exist"
    exit 1
done

declare -a selected=()
if [ "${EVENT_NAME}" != "pull_request" ] || [ "${ONLY_CHANGED}" = "false" ]; then
    selected=("${available[@]}")
else
    declare -a changed_files=()
    # Disabling rename detection keeps both sides of a move, so a directory a
    # file moved out of is selected as well as the destination directory.
    changed_files_file="${RUNNER_TEMP}/ast-metrics-changed-files"
    git diff --name-only --no-renames -z "${comparison_point}" HEAD -- > "${changed_files_file}"
    mapfile -d '' -t changed_files < "${changed_files_file}"

    analyze_all=false
    if [ "${isolated}" = "false" ]; then
        for changed_file in "${changed_files[@]}"; do
            case "${changed_file}" in
                .ast-metrics.yaml|.ast-metrics.yml|.ast-metrics.dist.yaml|.ast-metrics.dist.yml)
                    analyze_all=true
                    break
                    ;;
            esac
        done
    fi

    for relative_path in "${available[@]}"; do
        if [ "${analyze_all}" = "true" ]; then
            selected+=("${relative_path}")
            continue
        fi
        for changed_file in "${changed_files[@]}"; do
            if [ "${relative_path}" = "." ] \
                || [ "${changed_file}" = "${relative_path}" ] \
                || [[ "${changed_file}" == "${relative_path}/"* ]]; then
                selected+=("${relative_path}")
                break
            fi
        done
    done
fi

for relative_path in "${selected[@]}"; do
    printf '%s\n' "${relative_path}" >> "${selected_file}"
done

if [ "${#selected[@]}" -gt 0 ]; then
    has_directories=true
    echo "Analyzing: ${selected[*]}"
else
    has_directories=false
    echo "No configured directory needs analysis"
fi

{
    printf 'has-directories=%s\n' "${has_directories}"
    printf 'directories-file=%s\n' "${selected_file}"
    printf 'base-ref=%s\n' "${resolved_base_ref}"
    printf 'isolated=%s\n' "${isolated}"
} >> "${GITHUB_OUTPUT}"
