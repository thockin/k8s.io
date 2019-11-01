#!/usr/bin/env bash
#
# Copyright 2019 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# This script creates & configures one prod-like project.

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR=$(dirname "${BASH_SOURCE[0]}")
. "${SCRIPT_DIR}/lib.sh"

function usage() {
    echo "usage: $0 <project_name>" > /dev/stderr
    echo > /dev/stderr
}

if [ $# != 1 ]; then
    usage
    exit 1
fi

PROJ="$1"

color 6 "Ensuring project exists: ${PROJ}"
ensure_project "${PROJ}"

color 6 "Enabling the container registry API: ${PROJ}"
enable_api "${PROJ}" containerregistry.googleapis.com

color 6 "Enabling the container analysis API: ${PROJ}"
enable_api "${PROJ}" containeranalysis.googleapis.com

color 6 "Ensuring the GCR exists and is readable: ${PROJ}"
for r in "${PROD_GCR_REGIONS[@]}"; do
    color 3 "region $r"
    ensure_gcr_repo "${PROJ}" "${r}"
done

color 6 "Empowering GCR admins: ${PROJ}"
for r in "${PROD_GCR_REGIONS[@]}"; do
    color 3 "region $r"
    empower_gcr_admins "${PROJ}" "${r}"
done

color 6 "Empowering image promoter: ${PROJ}"
for r in "${PROD_GCR_REGIONS[@]}"; do
    color 3 "region $r"
    empower_artifact_promoter "${PROJ}" "${r}"
done

color 6 "Enabling the GCS API: ${PROJ}"
enable_api "${PROJ}" storage-component.googleapis.com

color 6 "Ensuring the GCS bucket exists and is readable: ${PROJ}"
ensure_public_gcs_bucket "${PROJ}" "gs://${PROJ}"

color 6 "Ensuring the GCS bucket retention policy is set: ${PROJ}"
RETENTION="10y"
ensure_gcs_bucket_retention "gs://${PROJ}" "${RETENTION}"

color 6 "Empowering GCS admins: ${PROJ}"
empower_gcs_admins "${PROJ}" "gs://${PROJ}"
