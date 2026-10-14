#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/vars.sh"

function load_ci_vars {
    if [[ -n "${GITHUB_RUN_ID:-}" ]]; then
        add_var 'CI' "GitHub"
        add_var 'RUN_ID' "${GITHUB_RUN_ID}"
        add_var 'REF_NAME' "${GITHUB_REF_NAME}"
        add_var 'REPOSITORY' "${GITHUB_REPOSITORY}"
        add_var 'WORKFLOW_ID' "${GITHUB_WORKFLOW}"
        add_var 'WORKFLOW_NAME' "${GITHUB_WORKFLOW}"
        add_var 'COMMIT_HASH' "${GITHUB_SHA}"

    elif [[ -n "${CI_PIPELINE_ID:-}" ]]; then
        add_var 'CI' "GitLab"
        add_var 'RUN_ID' "${CI_PIPELINE_ID}"
        add_var 'REF_NAME' "${CI_COMMIT_REF_NAME}"
        add_var 'REPOSITORY' "${CI_PROJECT_PATH}"
        add_var 'WORKFLOW_ID' "${CI_JOB_ID}"
        add_var 'WORKFLOW_NAME' "${CI_JOB_NAME}"
        add_var 'COMMIT_HASH' "${CI_COMMIT_SHA}"

    elif [[ -n "${BITBUCKET_BUILD_NUMBER:-}" ]]; then
        add_var 'CI' "Bitbucket"
        add_var 'RUN_ID' "${BITBUCKET_BUILD_NUMBER}"
        add_var 'REF_NAME' "${BITBUCKET_BRANCH}"
        add_var 'REPOSITORY' "${BITBUCKET_REPO_SLUG}"
        add_var 'WORKFLOW_ID' "${BITBUCKET_BUILD_NUMBER}"
        add_var 'WORKFLOW_NAME' "${BITBUCKET_BUILD_NUMBER}"
        add_var 'COMMIT_HASH' "${BITBUCKET_COMMIT}"

    elif [[ -n "${BUILD_NUMBER:-}" ]]; then
        add_var 'CI' "Bamboo"
        add_var 'RUN_ID' "${BUILD_NUMBER}"
        add_var 'REF_NAME' "${BRANCH_NAME}"
        add_var 'REPOSITORY' "${BUILD_REPOSITORY_NAME}"
        add_var 'WORKFLOW_ID' "${BUILD_NUMBER}"
        add_var 'WORKFLOW_NAME' "${BUILD_NAME:-$BUILD_NUMBER}"
        add_var 'COMMIT_HASH' "${BUILD_VCS_NUMBER}"

    elif [[ -n "${CIRCLE_WORKFLOW_ID:-}" ]]; then
        add_var 'CI' "CircleCI"
        add_var 'RUN_ID' "${CIRCLE_WORKFLOW_ID}"
        add_var 'REF_NAME' "${CIRCLE_BRANCH}"
        add_var 'REPOSITORY' "${CIRCLE_PROJECT_REPONAME}"
        add_var 'WORKFLOW_ID' "${CIRCLE_WORKFLOW_ID}"
        add_var 'WORKFLOW_NAME' "${CIRCLE_WORKFLOW_ID}"
        add_var 'COMMIT_HASH' "${CIRCLE_SHA1}"

    elif [[ -n "${BUILD_BUILDID:-}" ]]; then
        add_var 'CI' "AzureDevOps"
        add_var 'RUN_ID' "${BUILD_BUILDID}"
        add_var 'REF_NAME' "${BUILD_SOURCEBRANCHNAME:-unknown}"
        add_var 'REPOSITORY' "${BUILD_REPOSITORY_URI}"
        add_var 'WORKFLOW_ID' "${BUILD_BUILDID}"
        add_var 'WORKFLOW_NAME' "${BUILD_DEFINITIONNAME:-$BUILD_BUILDID}"
        add_var 'COMMIT_HASH' "${BUILD_SOURCEVERSION}"
    fi
}