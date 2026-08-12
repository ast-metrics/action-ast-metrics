#!/usr/bin/env bash

set -euo pipefail

: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${DIRECTORIES_FILE:?DIRECTORIES_FILE is required}"

MODE="${MODE:-}"
ISOLATED="${ISOLATED:-false}"
BASE_REF="${BASE_REF:-}"
FAIL_ON="${FAIL_ON:-never}"
MAX_FINDINGS="${MAX_FINDINGS:-5}"
WITH_SARIF="${WITH_SARIF:-false}"
SARIF_MAX_LEVEL="${SARIF_MAX_LEVEL:-}"

case "${MODE}" in
    review|analyze|html) ;;
    *)
        echo "::error::MODE must be 'review', 'analyze', or 'html'"
        exit 1
        ;;
esac

case "${ISOLATED}" in
    true|false) ;;
    *)
        echo "::error::ISOLATED must be either 'true' or 'false'"
        exit 1
        ;;
esac

repository_root="$(git rev-parse --show-toplevel)"
projects_root="${RUNNER_TEMP}/ast-metrics-project-reports"
mkdir -p "${projects_root}"

declare -a directories=()
mapfile -t directories < "${DIRECTORIES_FILE}"
if [ "${#directories[@]}" -eq 0 ]; then
    echo "::error::No directory was selected for analysis"
    exit 1
fi

project_context() {
    local directory="$1"
    if [ "${ISOLATED}" = "true" ]; then
        working_directory="${repository_root}/${directory}"
        analysis_target="."
    else
        working_directory="${repository_root}"
        analysis_target="${directory}"
    fi
}

html_report_path() {
    local html_root="$1"
    local directory="$2"
    if [ "${ISOLATED}" = "true" ]; then
        if [ "${directory}" = "." ]; then
            html_report="${html_root}/root"
        else
            html_report="${html_root}/${directory}"
        fi
    else
        html_report="${html_root}"
    fi
}

append_project_report() {
    local combined_report="$1"
    local directory="$2"
    local project_report="$3"

    if [ "${ISOLATED}" = "false" ]; then
        cp "${project_report}" "${combined_report}"
        return
    fi

    printf '## Project `%s`\n\n' "${directory//\`/\\\`}" >> "${combined_report}"
    # Nest the CLI headings below the project heading.
    sed 's/^#/##/' "${project_report}" >> "${combined_report}"
    printf '\n' >> "${combined_report}"
}

initialize_combined_report() {
    local combined_report="$1"
    : > "${combined_report}"
    if [ "${ISOLATED}" = "true" ]; then
        cat >> "${combined_report}" <<'EOF'
# AST Metrics monorepo report

Each project was analyzed independently with its local configuration.

EOF
    fi
}

run_review() {
    : "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required in review mode}"
    : "${BASE_REF:?BASE_REF is required in review mode}"

    local combined_markdown="${RUNNER_TEMP}/ast-metrics-review.md"
    local combined_json="${RUNNER_TEMP}/ast-metrics-review.json"
    local projects_json="${projects_root}/review-projects.jsonl"
    local sarif_projects_json="${projects_root}/sarif-projects.jsonl"
    initialize_combined_report "${combined_markdown}"
    : > "${projects_json}"
    : > "${sarif_projects_json}"

    local gate_code=0
    local index=0

    for directory in "${directories[@]}"; do
        index=$((index + 1))
        project_context "${directory}"

        local project_root="${projects_root}/$(printf '%03d' "${index}")"
        local markdown_report="${project_root}/review.md"
        local json_report="${project_root}/review.json"
        local sarif_report="${project_root}/review.sarif"
        mkdir -p "${project_root}"

        local -a sarif_args=()
        if [ "${WITH_SARIF}" = "true" ]; then
            sarif_args+=("--report-sarif=${sarif_report}")
            if [ -n "${SARIF_MAX_LEVEL}" ]; then
                sarif_args+=("--sarif-max-level=${SARIF_MAX_LEVEL}")
            fi
        fi

        echo "::group::AST Metrics review: ${directory}"
        set +e
        (
            cd "${working_directory}"
            ast-metrics review \
                --base "${BASE_REF}" \
                --fail-on "${FAIL_ON}" \
                --max-findings "${MAX_FINDINGS}" \
                --report-markdown "${markdown_report}" \
                --report-json "${json_report}" \
                "${sarif_args[@]}" \
                "${analysis_target}"
        )
        local code=$?
        set -e
        echo "::endgroup::"

        if [ ! -f "${markdown_report}" ] || [ ! -f "${json_report}" ]; then
            echo "::error::AST Metrics review failed for '${directory}' before producing its reports"
            if [ "${code}" -eq 0 ]; then
                exit 1
            fi
            exit "${code}"
        fi
        if ! jq empty "${json_report}" > /dev/null 2>&1; then
            echo "::error::AST Metrics produced invalid JSON for '${directory}'"
            exit 1
        fi
        if [ "${WITH_SARIF}" = "true" ]; then
            if [ ! -f "${sarif_report}" ] || ! jq empty "${sarif_report}" > /dev/null 2>&1; then
                echo "::error::AST Metrics did not produce valid SARIF for '${directory}'"
                exit 1
            fi
            jq -cn \
                --arg directory "${directory}" \
                --slurpfile report "${sarif_report}" \
                '{directory: $directory, report: $report[0]}' >> "${sarif_projects_json}"
        fi

        append_project_report "${combined_markdown}" "${directory}" "${markdown_report}"
        jq -cn \
            --arg directory "${directory}" \
            --slurpfile report "${json_report}" \
            '{directory: $directory, report: $report[0]}' >> "${projects_json}"

        if [ "${code}" -ne 0 ]; then
            gate_code=1
        fi
    done

    if [ "${ISOLATED}" = "false" ]; then
        cp "${projects_root}/001/review.json" "${combined_json}"
    else
        jq -s '
            def total($field): map(.report.summary[$field] // 0) | add // 0;
            {
                methodologyVersion: ([.[].report.methodologyVersion] | unique | join(", ")),
                baseRef: ([.[].report.baseRef] | unique | join(", ")),
                baseSha: ([.[].report.baseSha] | unique | join(", ")),
                headSha: ([.[].report.headSha] | unique | join(", ")),
                summary: {
                    filesChanged: total("filesChanged"),
                    filesAdded: total("filesAdded"),
                    filesDeleted: total("filesDeleted"),
                    high: total("high"),
                    medium: total("medium"),
                    low: total("low"),
                    improvements: total("improvements")
                },
                regressions: [.[].report.regressions[]?],
                improvements: [.[].report.improvements[]?],
                gate: (if any(.[]; .report.gate == "failed") then "failed" else "passed" end),
                projects: .
            }
        ' "${projects_json}" > "${combined_json}"
    fi

    if [ "${WITH_SARIF}" = "true" ]; then
        jq -s '
            {
                "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
                version: "2.1.0",
                runs: [
                    .[] as $project
                    | $project.report.runs[]
                    | .automationDetails.id = ("ast-metrics/" + $project.directory)
                ]
            }
        ' "${sarif_projects_json}" > "${RUNNER_TEMP}/ast-metrics-review.sarif"
    fi

    printf 'exit-code=%s\n' "${gate_code}" >> "${GITHUB_OUTPUT}"
}

run_analyze() {
    local combined_markdown="${RUNNER_TEMP}/ast-metrics-report.md"
    local html_root="${RUNNER_TEMP}/ast-metrics-html-report"
    initialize_combined_report "${combined_markdown}"
    mkdir -p "${html_root}"

    local index=0
    for directory in "${directories[@]}"; do
        index=$((index + 1))
        project_context "${directory}"

        local project_root="${projects_root}/$(printf '%03d' "${index}")"
        local markdown_report="${project_root}/report.md"
        html_report_path "${html_root}" "${directory}"
        mkdir -p "${project_root}"

        echo "::group::AST Metrics analysis: ${directory}"
        (
            cd "${working_directory}"
            ast-metrics analyze \
                --non-interactive \
                --report-html="${html_report}" \
                --report-markdown="${markdown_report}" \
                "${analysis_target}"
        )
        echo "::endgroup::"

        if [ ! -f "${markdown_report}" ]; then
            echo "::error::AST Metrics analysis failed for '${directory}' before producing its report"
            exit 1
        fi
        append_project_report "${combined_markdown}" "${directory}" "${markdown_report}"
    done
}

run_html() {
    local html_root="${RUNNER_TEMP}/ast-metrics-html-report"
    mkdir -p "${html_root}"

    for directory in "${directories[@]}"; do
        project_context "${directory}"
        html_report_path "${html_root}" "${directory}"

        echo "::group::AST Metrics HTML report: ${directory}"
        (
            cd "${working_directory}"
            ast-metrics analyze \
                --non-interactive \
                --report-html="${html_report}" \
                "${analysis_target}"
        )
        echo "::endgroup::"
    done
}

case "${MODE}" in
    review) run_review ;;
    analyze) run_analyze ;;
    html) run_html ;;
esac
