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

# This script is used to create a new "staging" repo in GCR, and a bucket in GCS.
#
# Each sub-project that needs to publish artifacts should have their
# own staging GCR repo & GCS bucket.
#
# Each staging bucket & repo exists in its own GCP project, and is writable by a
# dedicated googlegroup.

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

REPO="$1"

color 3 "Configuring staging: ${REPO}"

# The GCP project name.
PROJECT="k8s-staging-${REPO}"

# The group that can write to this staging repo.
WRITERS="k8s-infra-staging-${REPO}@kubernetes.io"

# The names of the buckets
STAGING_BUCKET="gs://${PROJECT}" # used by humans
GCB_BUCKET="gs://${PROJECT}-gcb" # used by GCB
ALL_BUCKETS=("${STAGING_BUCKET}" "${GCB_BUCKET}")

# A short expiration - it can always be raised, but it is hard to lower
# We expect promotion within 60d, or for testing to "move on", but
# it is also short enough that people should notice occasionally,
# and not accidentally think of the staging buckets as permanent.
AUTO_DELETION_DAYS=60

# Make the project, if needed
color 6 "Ensuring project exists: ${PROJECT}"
ensure_project "${PROJECT}"

# Enable writers to use the UI
color 6 "Empowering ${WRITERS} as project viewers"
empower_group_as_viewer "${PROJECT}" "${WRITERS}"

# Every project gets a GCR repo

# Enable container registry APIs
color 6 "Enabling the container registry API"
enable_api "${PROJECT}" containerregistry.googleapis.com

# Push an image to trigger the bucket to be created
color 6 "Ensuring the registry exists and is readable"
ensure_gcr_repo "${PROJECT}"

# Enable GCR admins
color 6 "Empowering GCR admins"
empower_gcr_admins "${PROJECT}"

# Enable GCR writers
color 6 "Empowering ${WRITERS} to GCR"
empower_group_to_gcr "${PROJECT}" "${WRITERS}"

# Every project gets some GCS buckets

# Enable GCS APIs
color 6 "Enabling the GCS API"
enable_api "${PROJECT}" storage-component.googleapis.com

for BUCKET in "${ALL_BUCKETS[@]}"; do
  color 3 "Configuring bucket: ${BUCKET}"

  # Create the bucket
  color 6 "Ensuring the bucket exists and is world readable"
  ensure_public_gcs_bucket "${PROJECT}" "${BUCKET}"

  # Set bucket auto-deletion
  color 6 "Ensuring the bucket has auto-deletion of ${AUTO_DELETION_DAYS} days"
  ensure_gcs_bucket_auto_deletion "${BUCKET}" "${AUTO_DELETION_DAYS}"

  # Enable admins on the bucket
  color 6 "Empowering GCS admins"
  empower_gcs_admins "${PROJECT}" "${BUCKET}"

  # Enable writers on the bucket
  color 6 "Empowering ${WRITERS} to GCS"
  empower_group_to_gcs_bucket "${WRITERS}" "${BUCKET}"
done

# Enable GCB and Prow to build and push images.

# Enable GCB APIs
color 6 "Enabling the GCB API"
enable_api "${PROJECT}" cloudbuild.googleapis.com

# Let sub-project writers use GCB.
color 6 "Empowering ${WRITERS} as GCB editors"
empower_group_for_gcb "${PROJECT}" "${WRITERS}"

# Let prow trigger builds and access the scratch bucket
color 6 "Empowering Prow"
empower_prow "${PROJECT}" "${GCB_BUCKET}"
