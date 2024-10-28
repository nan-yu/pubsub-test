#!/bin/bash

set -o xtrace

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# Required env variables
#GCP_PROJECT
#MAIL_USERNAME
#MAIL_PASSWORD

# Predefined variables
TOPIC=cs-topic
ZONE=us-central1-a
REGION=us-central1
CLUSTER_NAME=cs-pubsub-test
# The service account to build the cloud run function
CS_FUNCTION_BUILDER=cs-function-builder
# The service account for the calling function identity, which requires the roles/run.invoker role to invoke the specified function.
CS_FUNCTION_INVOKER=cs-function-invoker
# The service account used to authenticate to Google Cloud APIs from the Cloud Run service.
CS_RUN_SERVICE_SA=cs-run-service-sa
RUN_FUNCTION=cs-pubsub-functions-test
MAIL_PASSWD_NAME=cs-pubsub-mail-password
MAIL_USERNAME_NAME=cs-pubsub-mail-username

function main() {
  # Enable APIs
  gcloud services enable \
    artifactregistry.googleapis.com \
    cloudbuild.googleapis.com \
    pubsub.googleapis.com \
    run.googleapis.com \
    container.googleapis.com \
    compute.googleapis.com \
    secretmanager.googleapis.com \
    cloudfunctions.googleapis.com \
    eventarc.googleapis.com \
    --project=${GCP_PROJECT} || fail "failed to enable API services"

  # Cluster setup
  create_cluster
  install_config_sync

  # Create secrets in Secret Manager
  create_secrets

  # Create a Pub/Sub topic
  gcloud pubsub topics create ${TOPIC} --project=${GCP_PROJECT} ||
    fail "failed to create a Pub/Sub topic"

  # Cloud Run Functions setup
  set_iam_permissions
  deploy_function

  configure_root_sync_with_pubsub
}

function fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

function retry {
  local max="$1"
  shift
  local cmd=("$@")
  local n=1
  while (( n <= max )); do
    if "${cmd[@]}"; then
      break
    fi

    printf "Command failed. Attempt %d/%d:\n" "$n" "$max" >&2
    ((n++))
  done

  if (( n > max )); then
    fail "The command has failed after $max attempts."
  fi
}

function create_secrets() {
  printf ${MAIL_PASSWORD} | gcloud secrets create ${MAIL_PASSWD_NAME} \
    --data-file=- \
    --replication-policy=user-managed \
    --locations=${REGION} \
    --project=${GCP_PROJECT} || fail "failed to create a Secret for mail password"
  printf ${MAIL_USERNAME} | gcloud secrets create ${MAIL_USERNAME_NAME} \
    --data-file=- \
    --replication-policy=user-managed \
    --locations=${REGION} \
    --project=${GCP_PROJECT} || fail "failed to create a Secret for mail username"
}

function set_iam_permissions() {
  # Create a service account to build the cloud run function.
  gcloud iam service-accounts create ${CS_FUNCTION_BUILDER} \
    --display-name "Cloud Run Function builder" \
    --project=${GCP_PROJECT}  ||
    fail "failed to create a service account to build the cloud run function"

  # Create a service account for the cloud run function invoker.
  gcloud iam service-accounts create ${CS_FUNCTION_INVOKER} \
    --display-name "Cloud Run Function invoker" \
    --project=${GCP_PROJECT}  ||
    fail "failed to create a service account for the cloud run function invoker"

  # Create a service account for the cloud run service.
  gcloud iam service-accounts create ${CS_RUN_SERVICE_SA} \
    --display-name "Cloud Run service account" \
    --project=${GCP_PROJECT}  ||
    fail "failed to create a service account to build the cloud run function"

  (retry 3 gcloud iam service-accounts describe \
    ${CS_FUNCTION_BUILDER}@${GCP_PROJECT}.iam.gserviceaccount.com \
    --project=${GCP_PROJECT}) ||
    fail "expected the cloud run function builder to exist"
  (retry 3 gcloud iam service-accounts describe \
    ${CS_FUNCTION_INVOKER}@${GCP_PROJECT}.iam.gserviceaccount.com \
    --project=${GCP_PROJECT}) ||
    fail "expected the cloud run function invoker to exist"
  (retry 3 gcloud iam service-accounts describe \
    ${CS_RUN_SERVICE_SA}@${GCP_PROJECT}.iam.gserviceaccount.com \
    --project=${GCP_PROJECT}) ||
    fail "expected the cloud run service SA to exist"

  # Grant required permissions to the service accounts
  gcloud projects add-iam-policy-binding ${GCP_PROJECT} \
     --member=serviceAccount:${CS_FUNCTION_BUILDER}@${GCP_PROJECT}.iam.gserviceaccount.com \
     --role=roles/cloudbuild.builds.builder  ||
     fail "failed to grant cloudbuild.builds.builder permission to cloud run function builder"

  # Grant the secret accessor permission to the service account
  gcloud projects add-iam-policy-binding ${GCP_PROJECT} \
     --member=serviceAccount:${CS_RUN_SERVICE_SA}@${GCP_PROJECT}.iam.gserviceaccount.com \
     --role=roles/secretmanager.secretAccessor ||
     fail "failed to grant the secret accessor permission to the cloud run service account"
}

function deploy_function() {
  # Deploy the cloud run function with specific service accounts.
  # If no service-accounts are provided, it uses the GCE default service account:
  # https://cloud.google.com/functions/docs/securing/function-identity
  gcloud functions deploy ${RUN_FUNCTION} \
    --gen2 \
    --runtime=go121 \
    --region=${REGION} \
    --source=. \
    --entry-point=ConfigSync \
    --trigger-topic=${TOPIC} \
    --service-account ${CS_FUNCTION_INVOKER}@${GCP_PROJECT}.iam.gserviceaccount.com \
    --run-service-account ${CS_RUN_SERVICE_SA}@${GCP_PROJECT}.iam.gserviceaccount.com \
    --build-service-account projects/${GCP_PROJECT}/serviceAccounts/${CS_FUNCTION_BUILDER}@${GCP_PROJECT}.iam.gserviceaccount.com \
    --no-allow-unauthenticated \
    --update-secrets=MAIL_USER=${MAIL_USERNAME_NAME}:1,MAIL_PASSWD=${MAIL_PASSWD_NAME}:1 \
    --project=${GCP_PROJECT} ||
    fail "failed to deploy the cloud run function"

  gcloud run services add-iam-policy-binding ${RUN_FUNCTION} \
    --member=serviceAccount:${CS_FUNCTION_INVOKER}@${GCP_PROJECT}.iam.gserviceaccount.com  \
    --role=roles/run.invoker \
    --region=${REGION} \
    --project=${GCP_PROJECT} ||
     fail "failed to grant run.invoker permission to cloud run function invoker"

  gcloud run services add-iam-policy-binding ${RUN_FUNCTION} \
    --member=serviceAccount:${CS_RUN_SERVICE_SA}@${GCP_PROJECT}.iam.gserviceaccount.com  \
    --role=roles/run.invoker \
    --region=${REGION} \
    --project=${GCP_PROJECT} ||
     fail "failed to grant run.invoker permission to cloud run service SA"
}

function create_cluster() {
  gcloud container clusters create ${CLUSTER_NAME} \
    --release-channel regular \
    --zone ${ZONE} \
    --workload-pool "${GCP_PROJECT}.svc.id.goog" \
    --project=${GCP_PROJECT} ||
    fail "failed to create a Kubernetes cluster"

  # Connect to the cluster
  gcloud container clusters get-credentials ${CLUSTER_NAME} \
    --zone ${ZONE} \
    --project ${GCP_PROJECT} ||
    fail "failed to connect to the cluster"

  # Grant the GCE default service account permissions to allow image pull
  project_numer=$(gcloud projects describe ${GCP_PROJECT} --format=json | jq -r .projectNumber || '')
  gcloud projects add-iam-policy-binding ${GCP_PROJECT} \
     --member=serviceAccount:${project_numer}-compute@developer.gserviceaccount.com \
     --role=roles/artifactregistry.reader ||
     fail "failed to grant the GCE default service account permissions to allow image pull"
}

function install_config_sync() {
  # Install Config Sync with the pubsub feature
  path=/tmp/config-sync-pubsub-test
  rm -rf ${path} && mkdir ${path}
  git -C ${path} clone git@github.com:nan-yu/kpt-config-sync.git -b pubsub
  pushd ${path}/kpt-config-sync
  GCP_PROJECT=${GCP_PROJECT} IMAGE_TAG=pubsub-test make config-sync-manifest
  kubectl apply -f .output/staging/oss/config-sync-manifest.yaml
  popd
}

function configure_root_sync_with_pubsub() {
  # Grant the KSA permissions to publish messages to Pub/Sub.
  gcloud projects add-iam-policy-binding ${GCP_PROJECT} \
    --role=roles/pubsub.publisher \
    --member="serviceAccount:${GCP_PROJECT}.svc.id.goog[config-management-system/root-reconciler]"

  # Config RootSync with pubsub enabled
  cat > root-sync.yaml <<EOF
apiVersion: configsync.gke.io/v1beta1
kind: RootSync
metadata:
  name: root-sync
  namespace: config-management-system
spec:
  git:
    auth: none
    branch: main
    dir: foo-corp
    repo: https://github.com/GoogleCloudPlatform/anthos-config-management-samples
  pubsub:
    enabled: true
    topic: ${TOPIC}
EOF
  kubectl apply -f root-sync.yaml
  rm root-sync.yaml
}

main