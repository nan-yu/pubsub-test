#!/bin/bash

set -o xtrace

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# Required env variables
#GCP_PROJECT
#MAIL_USERNAME
#MAIL_PASSWORD

# Predefined variables
TOPIC=cs-topic
AR_REPO=cs-pubsub-test
ZONE=us-central1-a
REGION=us-central1
CLUSTER_NAME=cs-pubsub-test
RUN_BUILD_SA=cs-run-builder # The service account to build the cloud run service
PUBSUB_INVOKER=cs-run-pubsub-invoker  # The service account to represent the Pub/Sub subscription identity
RUN_SERVICE_IDENTITY=cs-run-identity # The service account used to authenticate to Google Cloud APIs from the Cloud Run instance container.
RUN_SERVICE=cs-pubsub-test
MAIL_PASSWD_NAME=cs-pubsub-mail-password
MAIL_USERNAME_NAME=cs-pubsub-mail-username
PUBSUB_SUBSCRIPTION_NAME=cs-pubsub-subscription

api_services=(
  "artifactregistry.googleapis.com"
  "cloudbuild.googleapis.com"
  "pubsub.googleapis.com"
  "run.googleapis.com"
  "container.googleapis.com"
  "compute.googleapis.com"
  "secretmanager.googleapis.com"
)

function main() {
  # Enable APIs
  enable_api_services

  # Cluster setup
  create_cluster
  install_config_sync

  # Create secrets in Secret Manager
  create_secrets

  # Cloud Run setup
  create_ar_repository
  build_and_publish_run_service
  deploy_run_service

  # Pub/Sub setup
  # Create a Pub/Sub topic
  gcloud pubsub topics create ${TOPIC} --project=${GCP_PROJECT} ||
    fail "failed to create a Pub/Sub topic"
  configure_pubsub
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

function check_all_api_services_enabled() {
  for api_service in "${api_services[@]}"; do
    if ! gcloud services list | grep -q "${api_service}"; then
      echo "API service not enabled: ${api_service}"
      return 1
    fi
  done
}

function enable_api_services() {
  echo "Enabling API services"
  for api_service in "${api_services[@]}"; do
    gcloud services enable "${api_service}" --project=${GCP_PROJECT} ||
      fail "failed to enable API services ${api_service}"
  done

  retry 3 check_all_api_services_enabled || fail "Not all API services are enabled"
}

function configure_pubsub() {
  echo "Creating a service account to represent the Pub/Sub subscription identity"
  gcloud iam service-accounts create ${PUBSUB_INVOKER} \
    --display-name "Cloud Run Pub/Sub Invoker" \
    --project=${GCP_PROJECT} ||
    fail "failed to create a Pub/Sub invoker"

  (retry 3 gcloud iam service-accounts describe \
    ${PUBSUB_INVOKER}@${GCP_PROJECT}.iam.gserviceaccount.com \
    --project=${GCP_PROJECT}) ||
    fail "expected the Pub/Sub invoker to exist"
  # Grant the invoker service account permission to invoke the cloud run service.
  gcloud run services add-iam-policy-binding ${RUN_SERVICE} \
    --member=serviceAccount:${PUBSUB_INVOKER}@${GCP_PROJECT}.iam.gserviceaccount.com \
    --role=roles/run.invoker \
    --region=${REGION} \
    --project=${GCP_PROJECT} ||
    fail "failed to grant the permission to invoke the cloud run service"

  # Allow Pub/Sub to create authentication tokens in the project.
  project_numer=$(gcloud projects describe ${GCP_PROJECT} --format=json | jq -r .projectNumber || "")
  gcloud projects add-iam-policy-binding ${GCP_PROJECT} \
     --member=serviceAccount:service-${project_numer}@gcp-sa-pubsub.iam.gserviceaccount.com \
     --role=roles/iam.serviceAccountTokenCreator ||
     fail "failed to grant serviceAccountTokenCreator role permissions"

  # Create a Pub/Sub subscription with the service account
  push_endpoint=$(gcloud run services describe ${RUN_SERVICE} \
   --platform managed \
   --region $REGION  \
   --project=${GCP_PROJECT} \
   --format 'value(status.url)' || '')
  gcloud pubsub subscriptions create ${PUBSUB_SUBSCRIPTION_NAME} \
    --topic ${TOPIC} \
    --ack-deadline=600 \
    --push-endpoint=${push_endpoint} \
    --push-auth-service-account=${PUBSUB_INVOKER}@${GCP_PROJECT}.iam.gserviceaccount.com \
    --project=${GCP_PROJECT} ||
    fail "failed to create a Pub/Sub subscription"
}

function create_ar_repository() {
  gcloud artifacts repositories create ${AR_REPO} \
    --repository-format=docker \
    --location=${REGION} \
    --project=${GCP_PROJECT} ||
    fail "failed to create a registry in GAR"
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

function build_and_publish_run_service() {
  # Create a service account to build the cloud run service.
  gcloud iam service-accounts create ${RUN_BUILD_SA} \
    --display-name "Cloud Run Builder" \
    --project=${GCP_PROJECT}  ||
    fail "failed to create a service account to build the cloud run service"

  (retry 3 gcloud iam service-accounts describe \
    ${RUN_BUILD_SA}@${GCP_PROJECT}.iam.gserviceaccount.com \
    --project=${GCP_PROJECT}) ||
    fail "expected the cloud run builder to exist"
  # Grant required permissions to the service account
  gcloud projects add-iam-policy-binding ${GCP_PROJECT} \
     --member=serviceAccount:${RUN_BUILD_SA}@${GCP_PROJECT}.iam.gserviceaccount.com \
     --role=roles/logging.logWriter ||
     fail "failed to grant logging.logWriter permission to cloud run builder"
  gcloud projects add-iam-policy-binding ${GCP_PROJECT} \
     --member=serviceAccount:${RUN_BUILD_SA}@${GCP_PROJECT}.iam.gserviceaccount.com \
     --role=roles/run.sourceDeveloper||
     fail "failed to grant run.sourceDeveloper permission to cloud run builder"
  gcloud projects add-iam-policy-binding ${GCP_PROJECT} \
     --member=serviceAccount:${RUN_BUILD_SA}@${GCP_PROJECT}.iam.gserviceaccount.com \
     --role=roles/storage.admin ||
     fail "failed to grant storage.admin permission to cloud run builder"
  gcloud projects add-iam-policy-binding ${GCP_PROJECT} \
     --member=serviceAccount:${RUN_BUILD_SA}@${GCP_PROJECT}.iam.gserviceaccount.com \
     --role=roles/artifactregistry.writer ||
     fail "failed to grant artifactregistry.writer permission to cloud run builder"

  # Using a specific service account by setting the --service-account flag.
  # If no service-account is provided, it uses the GCE default service account:
  # https://cloud.google.com/build/docs/cloud-build-service-account.
  # When service-account is specified, it also requires setting the default bucket behavior.
  pushd ${SCRIPT_DIR}
  gcloud builds submit \
    --tag ${REGION}-docker.pkg.dev/${GCP_PROJECT}/${AR_REPO}/pubsub \
    --service-account projects/${GCP_PROJECT}/serviceAccounts/${RUN_BUILD_SA}@${GCP_PROJECT}.iam.gserviceaccount.com \
    --default-buckets-behavior=regional-user-owned-bucket \
    --project ${GCP_PROJECT} ||
    fail "failed to build the cloud run service"
  popd
}

function deploy_run_service() {
  # Create a service account for the cloud run service identity.
  gcloud iam service-accounts create ${RUN_SERVICE_IDENTITY} \
    --display-name "Cloud Run Service Identity" \
    --project=${GCP_PROJECT} ||
    fail "failed to create the cloud run service identity"

  (retry 3 gcloud iam service-accounts describe \
    ${RUN_SERVICE_IDENTITY}@${GCP_PROJECT}.iam.gserviceaccount.com \
    --project=${GCP_PROJECT}) ||
    fail "expected the cloud run service identity to exist"
  # Grant the secret accessor permission to the service account
  gcloud projects add-iam-policy-binding ${GCP_PROJECT} \
     --member=serviceAccount:${RUN_SERVICE_IDENTITY}@${GCP_PROJECT}.iam.gserviceaccount.com \
     --role=roles/secretmanager.secretAccessor ||
     fail "failed to grant the secret accessor permission to the service account"
  # Deploy the cloud run service with a specific service account.
  # If no service-account is provided, it uses the GCE default service account:
  # https://cloud.google.com/run/docs/securing/service-identity
  gcloud run deploy ${RUN_SERVICE} \
    --image ${REGION}-docker.pkg.dev/${GCP_PROJECT}/${AR_REPO}/pubsub \
    --no-allow-unauthenticated \
    --service-account ${RUN_SERVICE_IDENTITY}@${GCP_PROJECT}.iam.gserviceaccount.com \
    --region ${REGION} \
    --update-secrets=MAIL_USER=${MAIL_USERNAME_NAME}:1,MAIL_PASSWD=${MAIL_PASSWD_NAME}:1 \
    --project=${GCP_PROJECT} ||
    fail "failed to deploy the cloud run service"
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