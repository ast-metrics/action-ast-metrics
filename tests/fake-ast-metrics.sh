#!/usr/bin/env bash

set -euo pipefail

: "${AST_METRICS_TEST_LOG:?AST_METRICS_TEST_LOG is required}"

command_name="${1:-}"
shift || true

markdown_report=""
json_report=""
sarif_report=""
html_report=""
target=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --report-markdown=*) markdown_report="${1#*=}" ;;
        --report-markdown)
            shift
            markdown_report="${1:-}"
            ;;
        --report-json=*) json_report="${1#*=}" ;;
        --report-json)
            shift
            json_report="${1:-}"
            ;;
        --report-sarif=*) sarif_report="${1#*=}" ;;
        --report-sarif)
            shift
            sarif_report="${1:-}"
            ;;
        --report-html=*) html_report="${1#*=}" ;;
        --report-html)
            shift
            html_report="${1:-}"
            ;;
        --base|--fail-on|--max-findings|--sarif-max-level)
            shift
            ;;
        --*) ;;
        *) target="$1" ;;
    esac
    shift || true
done

configuration="none"
if [ -f .ast-metrics.yaml ]; then
    configuration="$(tr '\n' ',' < .ast-metrics.yaml)"
fi
printf '%s|%s|%s|%s\n' "${PWD}" "${command_name}" "${target}" "${configuration}" >> "${AST_METRICS_TEST_LOG}"

project="$(basename "${PWD}")"

# The real CLI reports paths relative to the repository root, whatever directory
# it runs from and whatever target it receives. Reproduce that, so the tests
# catch an aggregation that would leak project relative paths into the
# annotations and the SARIF locations.
analyzed_directory="$(git rev-parse --show-prefix)"
if [ -n "${target}" ] && [ "${target}" != "." ]; then
    analyzed_directory="${analyzed_directory}${target%/}/"
fi
analyzed_file="${analyzed_directory}source.php"

gate="passed"
if [ -f .ast-metrics.yaml ] && grep -q '^fail: true$' .ast-metrics.yaml; then
    gate="failed"
fi

if [ -n "${markdown_report}" ]; then
    mkdir -p "$(dirname "${markdown_report}")"
    printf '## AST Metrics: quality gate %s\n\nConfiguration: %s\n' "${gate}" "${configuration}" > "${markdown_report}"
fi

if [ -n "${json_report}" ]; then
    mkdir -p "$(dirname "${json_report}")"
    jq -n \
        --arg file "${analyzed_file}" \
        --arg gate "${gate}" \
        '{
            methodologyVersion: "test",
            baseRef: "origin/main",
            baseSha: "base",
            headSha: "head",
            summary: {
                filesChanged: 1,
                filesAdded: 0,
                filesDeleted: 0,
                high: (if $gate == "failed" then 1 else 0 end),
                medium: 0,
                low: 0,
                improvements: 0
            },
            regressions: (if $gate == "failed" then [{
                kind: "regression",
                severity: "high",
                rule: "test-rule",
                file: $file,
                line: 1,
                message: "test"
            }] else [] end),
            improvements: [],
            gate: $gate
        }' > "${json_report}"
fi

if [ -n "${sarif_report}" ]; then
    mkdir -p "$(dirname "${sarif_report}")"
    jq -n \
        --arg project "${project}" \
        --arg file "${analyzed_file}" \
        '{
            "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
            version: "2.1.0",
            runs: [{
                tool: {driver: {name: "ast-metrics"}},
                automationDetails: {id: $project},
                results: [{
                    ruleId: "test-rule",
                    level: "warning",
                    message: {text: "test"},
                    locations: [{
                        physicalLocation: {artifactLocation: {uri: $file}}
                    }]
                }]
            }]
        }' > "${sarif_report}"
fi

if [ -n "${html_report}" ]; then
    mkdir -p "${html_report}"
    printf '<html>%s</html>\n' "${configuration}" > "${html_report}/index.html"
fi

if [ "${command_name}" = "review" ] && [ "${gate}" = "failed" ]; then
    exit 1
fi
