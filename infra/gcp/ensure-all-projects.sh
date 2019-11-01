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

# This script creates & configures GCP projects k8s-infra

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR=$(dirname "${BASH_SOURCE[0]}")
cd "${SCRIPT_DIR}"
source ./lib.sh

function usage() {
    echo "usage: $0" > /dev/stderr
    echo > /dev/stderr
}

# TODO: take a list of args saying which projects to do.
if [ $# != 0 ]; then
    usage
    exit 1
fi

# Grant access to "fake prod" projects for testing
# $1: The GCP project
# $2: The googlegroups group
function empower_group_to_fake_prod() {
    if [ $# -lt 2 -o -z "$1" -o -z "$2" ]; then
        echo "empower_group_to_fake_prod(project, group) requires 2 arguments" >&2
        return 1
    fi
    project="$1"
    group="$2"

    color 6 "Empowering $group as project viewer in $project"
    empower_group_as_viewer "${project}" "${group}"

    color 6 "Empowering $group for GCR in $project"
    for r in "${PROD_GCR_REGIONS[@]}"; do
        color 3 "region $r"
        empower_group_to_gcr "${project}" "${group}" "${r}"
    done
}

#################################################################
#################################################################
# main
#################################################################
#################################################################

#////////////////////////////////////////////////////////////////
# This is the "real" prod project for artifacts serving and backups.

PROD_PROJECT="k8s-artifacts-prod"
PRODBAK_PROJECT="${PROD_PROJECT}-bak"

./prod-project.sh "${PROD_PROJECT}"
./prod-project.sh "${PRODBAK_PROJECT}"

# Special case: set the web policy on the prod bucket.
color 6 "Configuring the web policy on the bucket"
ensure_gcs_web_policy "gs://${PROD_PROJECT}"

# Special case: rsync static content into the prod bucket.
color 6 "Copying static content into bucket"
upload_gcs_static_content \
    "gs://${PROD_PROJECT}" \
    "${SCRIPT_DIR}/static/prod-storage"

# Special case: set up GCLB frontend.
./ensure-prod-storage-gclb.sh

#////////////////////////////////////////////////////////////////
# These are for testing the image promoter's promotion process.

PROMOTER_TEST_PROD_PROJECT="k8s-cip-test-prod"
PROMOTER_TEST_STAGING="cip-test"
PROMOTER_TEST_STAGING_PROJECT="k8s-staging-${PROMOTER_TEST_STAGING}"

./prod-project.sh "${PROMOTER_TEST_PROD_PROJECT}"
./staging-project.sh "${PROMOTER_TEST_STAGING}"

# Special case: don't use retention on cip-test buckets
gsutil retention clear "gs://${PROMOTER_TEST_PROD_PROJECT}"

# Special case: grant the image promoter testing group access to their fake
# prod projects.
empower_group_to_fake_prod \
    "${PROMOTER_TEST_PROD_PROJECT}" \
    "k8s-infra-staging-cip-test@kubernetes.io"

# Special case: grant the image promoter test service account access to their
# staging, to allow e2e tests to run as that account, instead of yet another.
empower_service_account_to_artifacts \
    $(svc_acct_email "${PROMOTER_TEST_PROD_PROJECT}" "${PROMOTER_SVCACCT}") \
    "${PROMOTER_TEST_STAGING_PROJECT}"

#////////////////////////////////////////////////////////////////
# These are for testing the GCR backup/restore process.

GCR_BACKUP_TEST_PROD_PROJECT="k8s-gcr-backup-test-prod"
GCR_BACKUP_TEST_PRODBAK_PROJECT="${GCR_BACKUP_TEST_PROD_PROJECT}-bak"

./prod-project.sh "${GCR_BACKUP_TEST_PROD_PROJECT}"
./prod-project.sh "${GCR_BACKUP_TEST_PRODBAK_PROJECT}"

# Special case: grant the image promoter testing group access to their fake
# prod projects.
empower_group_to_fake_prod \
    "${GCR_BACKUP_TEST_PROD_PROJECT}" \
    "k8s-infra-staging-cip-test@kubernetes.io"
empower_group_to_fake_prod \
    "${GCR_BACKUP_TEST_PRODBAK_PROJECT}" \
    "k8s-infra-staging-cip-test@kubernetes.io"

#////////////////////////////////////////////////////////////////
# These are for testing the GCR auditing process.

GCR_AUDIT_TEST_PROD_PROJECT="k8s-gcr-audit-test-prod"

./prod-project.sh "${GCR_AUDIT_TEST_PROD_PROJECT}"

# Special case: grant the image promoter testing group access to their fake
# prod projects.
empower_group_to_fake_prod \
    "${GCR_AUDIT_TEST_PROD_PROJECT}" \
    "k8s-infra-staging-cip-test@kubernetes.io"

#////////////////////////////////////////////////////////////////
# This is for testing the release tools.

RELEASE_TEST_PROD_PROJECT="k8s-release-test-prod"
RELEASE_TEST_STAGING="release-test"
RELEASE_TEST_STAGING_PROJECT="k8s-staging-${RELEASE_TEST_STAGING}"

./prod-project.sh "${RELEASE_TEST_PROD_PROJECT}"
./staging-project.sh "${PROMOTER_TEST_STAGING}"

# Special case: grant the release tools testing group access to their fake
# prod project.
empower_group_to_fake_prod \
    "${RELEASE_TEST_PROD_PROJECT}" \
    "k8s-infra-staging-release-test@kubernetes.io"

#////////////////////////////////////////////////////////////////
# These are sub-project staging repos, and should never need special-casing.

# NB: Please keep this sorted.
STAGING_SUBPROJECTS=(
    artifact-promoter
    build-image
    cluster-api
    cluster-api-aws
    cluster-api-azure
    cluster-api-gcp
    capi-openstack
    capi-kubeadm
    capi-docker
    coredns
    csi
    descheduler
    kas-network-proxy
    kops
    kube-state-metrics
    multitenancy
    publishing-bot
)

for REPO in "${STAGING_SUBPROJECTS[@]}"; do
    ./staging-project.sh "${REPO}"
done


exit 42
#FIXME: both need GCB?
#FIXME: both need KMS?
#FIXME: need regional GCRs?
PROJECTS=(
    k8s-staging-release-test
    k8s-release-test-prod
)

ADMINS="k8s-infra-release-admins@kubernetes.io"
WRITERS="k8s-infra-release-editors@kubernetes.io"
VIEWERS="k8s-infra-release-viewers@kubernetes.io"

for PROJECT; do
    color 3 "Configuring: ${PROJECT}"

    # The names of the buckets
    STAGING_BUCKET="gs://${PROJECT}" # used by humans
    GCB_BUCKET="gs://${PROJECT}-gcb" # used by GCB
    ALL_BUCKETS=("${STAGING_BUCKET}" "${GCB_BUCKET}")

    # Make the project, if needed
    color 6 "Ensuring project exists: ${PROJECT}"
    ensure_project "${PROJECT}"

    for group in ${ADMINS} ${WRITERS} ${VIEWERS}; do
        # Enable admins to use the UI
        color 6 "Empowering ${group} as project viewers"
        empower_group_as_viewer "${PROJECT}" "${group}"
    done

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
    for group in ${ADMINS} ${WRITERS}; do
        color 6 "Empowering ${group} to GCR"
        empower_group_to_gcr "${PROJECT}" "${group}"
    done

    # Every project gets some GCS buckets

    # Enable GCS APIs
    color 6 "Enabling the GCS API"
    enable_api "${PROJECT}" storage-component.googleapis.com

    for BUCKET in "${ALL_BUCKETS[@]}"; do
        color 3 "Configuring bucket: ${BUCKET}"

        # Create the bucket
        color 6 "Ensuring the bucket exists and is world readable"
        ensure_public_gcs_bucket "${PROJECT}" "${BUCKET}"

        # Enable admins on the bucket
        color 6 "Empowering GCS admins"
        empower_gcs_admins "${PROJECT}" "${BUCKET}"

        # Enable writers on the bucket
        for group in ${ADMINS} ${WRITERS}; do
            color 6 "Empowering ${group} to GCS"
            empower_group_to_gcs_bucket "${group}" "${BUCKET}"
        done
    done

    # Enable GCB and Prow to build and push images.

    # Enable GCB APIs
    color 6 "Enabling the GCB API"
    enable_api "${PROJECT}" cloudbuild.googleapis.com

    # Let project writers use GCB.
    for group in ${ADMINS} ${WRITERS}; do
        color 6 "Empowering ${group} as GCB editors"
        empower_group_for_gcb "${PROJECT}" "${group}"
    done

    # Let prow trigger builds and access the scratch bucket
    color 6 "Empowering Prow"
    empower_prow "${PROJECT}" "${GCB_BUCKET}"

    # Enable KMS APIs
    color 6 "Enabling the KMS API"
    enable_api "${PROJECT}" cloudkms.googleapis.com

    # Let project admins use KMS.
    color 6 "Empowering ${ADMINS} as KMS admins"
    empower_group_for_kms "${PROJECT}" "${ADMINS}"

    color 6 "Done"
done
