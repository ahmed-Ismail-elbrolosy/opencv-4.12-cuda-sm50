#!/usr/bin/env bash
set -euo pipefail

readonly DIST_DIR="${1:?dist directory is required}"

subjects="$({
    cd "${DIST_DIR}"
    jq -Rn \
        '[inputs | select(length > 0) | capture("^(?<hash>[0-9a-f]{64}) [ *](?<name>.+)$") | {name: .name, digest: {sha256: .hash}}]' \
        < SHA256SUMS
})"

jq -n \
    --argjson subjects "${subjects}" \
    --arg repository "${GITHUB_REPOSITORY:?}" \
    --arg commit "${GITHUB_SHA:?}" \
    --arg workflow_ref "${GITHUB_WORKFLOW_REF:?}" \
    --arg workflow_sha "${GITHUB_WORKFLOW_SHA:?}" \
    --arg run_id "${GITHUB_RUN_ID:?}" \
    --arg run_attempt "${GITHUB_RUN_ATTEMPT:?}" \
    --arg event "${GITHUB_EVENT_NAME:?}" \
    --arg runner_image "${ImageVersion:-unknown}" \
    --arg opencv_commit "49486f61fb25722cbcf586b7f4320921d46fb38e" \
    --arg contrib_commit "d943e1d61c8bc556a13783e1546ee7c1a9e0b1cf" \
    --arg cuda_md5 "a52d6c204bd4268627dfdab8bfeeb0d1" \
    --arg libxml_sha256 "a2c9ae7b770da34860050c309f903221c67830c86e4a7e760692b803df95143a" \
    '{
        _type: "https://in-toto.io/Statement/v1",
        subject: $subjects,
        predicateType: "https://slsa.dev/provenance/v1",
        predicate: {
            buildDefinition: {
                buildType: "https://github.com/actions/workflow/v1",
                externalParameters: {event: $event},
                internalParameters: {runnerImage: $runner_image},
                resolvedDependencies: [
                    {uri: ("git+https://github.com/" + $repository), digest: {gitCommit: $commit}},
                    {uri: $workflow_ref, digest: {gitCommit: $workflow_sha}},
                    {uri: "git+https://github.com/opencv/opencv.git", digest: {gitCommit: $opencv_commit}},
                    {uri: "git+https://github.com/opencv/opencv_contrib.git", digest: {gitCommit: $contrib_commit}},
                    {uri: "https://developer.download.nvidia.com/compute/cuda/12.9.1/local_installers/cuda_12.9.1_575.57.08_linux.run", digest: {md5: $cuda_md5}},
                    {uri: "https://download.gnome.org/sources/libxml2/2.13/libxml2-2.13.9.tar.xz", digest: {sha256: $libxml_sha256}}
                ]
            },
            runDetails: {
                builder: {id: "https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2604-Readme.md"},
                metadata: {invocationId: ("https://github.com/" + $repository + "/actions/runs/" + $run_id + "/attempts/" + $run_attempt)}
            }
        }
    }' > "${DIST_DIR}/provenance.intoto.json"

jq empty "${DIST_DIR}/provenance.intoto.json"
