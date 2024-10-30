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
CS_APP_DEPLOYER=cs-app-deployer # The service account that this deployed version will run as.
APP_REGION=us-central
PUBSUB_INVOKER=cs-run-pubsub-invoker  # The service account to represent the Pub/Sub subscription identity
PUBSUB_SUBSCRIPTION_NAME=cs-pubsub-subscription
MAIL_PASSWD_NAME=cs-pubsub-mail-password
MAIL_USERNAME_NAME=cs-pubsub-mail-username

api_services=(
  "pubsub.googleapis.com"
  "appengineflex.googleapis.com"
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

  # Create a Pub/Sub topic
  gcloud pubsub topics create ${TOPIC} --project=${GCP_PROJECT} ||
    fail "failed to create a Pub/Sub topic"

  # Cloud App Engine setup
  create_and_deploy_app

 # Pub/Sub setup
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

function create_and_deploy_app() {
  # Create a service account to build the cloud run function.
  # Create a specific service account to deploy the app.
  # If no service-account is provided, it uses the App Engine's default service account:
  # https://cloud.google.com/appengine/docs/standard/configure-service-accounts
  gcloud iam service-accounts create ${CS_APP_DEPLOYER} \
      --display-name "The service account that this deployed version will run as" \
      --project ${GCP_PROJECT} ||
      fail "failed to create an app deployer"

  (retry 3 gcloud iam service-accounts describe \
    ${CS_APP_DEPLOYER}@${GCP_PROJECT}.iam.gserviceaccount.com \
    --project=${GCP_PROJECT}) ||
    fail "expected the app service account to exist"

  gcloud app create --region=${APP_REGION} \
    --service-account=${CS_APP_DEPLOYER}@${GCP_PROJECT}.iam.gserviceaccount.com \
    --project=${GCP_PROJECT} ||
    fail "failed to create an App Engine app"

  # Grant required permissions to the app deployer.
  # https://github.com/google-github-actions/setup-gcloud/issues/191#issuecomment-706105206
  gcloud projects add-iam-policy-binding ${GCP_PROJECT} \
    --member=serviceAccount:${CS_APP_DEPLOYER}@${GCP_PROJECT}.iam.gserviceaccount.com \
    --role=roles/appengine.deployer ||
    fail "failed to grant appengine.deployer role to th app deployer"

  gcloud projects add-iam-policy-binding ${GCP_PROJECT} \
    --member=serviceAccount:${CS_APP_DEPLOYER}@${GCP_PROJECT}.iam.gserviceaccount.com \
    --role=roles/appengine.serviceAdmin ||
    fail "failed to grant appengine.serviceAdmin role to th app deployer"

  gcloud projects add-iam-policy-binding ${GCP_PROJECT} \
    --member=serviceAccount:${CS_APP_DEPLOYER}@${GCP_PROJECT}.iam.gserviceaccount.com \
    --role=roles/cloudbuild.builds.builder ||
    fail "failed to grant cloudbuild.builds.builder role to th app deployer"

  gcloud projects add-iam-policy-binding ${GCP_PROJECT} \
    --member=serviceAccount:${CS_APP_DEPLOYER}@${GCP_PROJECT}.iam.gserviceaccount.com \
    --role=roles/iam.serviceAccountUser ||
    fail "failed to grant iam.serviceAccountUser role to th app deployer"

  gcloud projects add-iam-policy-binding ${GCP_PROJECT} \
    --member=serviceAccount:${CS_APP_DEPLOYER}@${GCP_PROJECT}.iam.gserviceaccount.com \
    --role=roles/storage.objectCreator ||
    fail "failed to grant storage.objectCreator role to th app deployer"

  gcloud projects add-iam-policy-binding ${GCP_PROJECT} \
    --member=serviceAccount:${CS_APP_DEPLOYER}@${GCP_PROJECT}.iam.gserviceaccount.com \
    --role=roles/storage.objectViewer ||
    fail "failed to grant storage.objectViewer role to th app deployer"

  gcloud projects add-iam-policy-binding ${GCP_PROJECT} \
    --member=serviceAccount:${CS_APP_DEPLOYER}@${GCP_PROJECT}.iam.gserviceaccount.com \
    --role=roles/secretmanager.secretAccessor ||
    fail "failed to grant secretmanager.secretAccessor role to th app deployer"

  gcloud projects add-iam-policy-binding ${GCP_PROJECT} \
    --member=serviceAccount:${CS_APP_DEPLOYER}@${GCP_PROJECT}.iam.gserviceaccount.com \
    --role=roles/pubsub.viewer ||
    fail "failed to grant pubsub.viewer role to th app deployer"

  gcloud projects add-iam-policy-binding ${GCP_PROJECT} \
    --member=serviceAccount:${CS_APP_DEPLOYER}@${GCP_PROJECT}.iam.gserviceaccount.com \
    --role=roles/monitoring.metricWriter ||
    fail "failed to grant monitoring.metricWriter role to th app deployer"


  pushd ${SCRIPT_DIR}
  gcloud app deploy -q \
    --service-account=${CS_APP_DEPLOYER}@${GCP_PROJECT}.iam.gserviceaccount.com \
    --project=${GCP_PROJECT} ||
    fail "failed to deploy the app"

  popd
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

  # Allow Pub/Sub to create authentication tokens in the project.
  project_numer=$(gcloud projects describe ${GCP_PROJECT} --format=json | jq -r .projectNumber || "")
  gcloud projects add-iam-policy-binding ${GCP_PROJECT} \
     --member=serviceAccount:service-${project_numer}@gcp-sa-pubsub.iam.gserviceaccount.com \
     --role=roles/iam.serviceAccountTokenCreator ||
     fail "failed to grant serviceAccountTokenCreator role permissions"

  app_service_url=$(gcloud app versions list --hide-no-traffic \
    --service=default --project=${GCP_PROJECT} --format=json \
    | jq -r .[0].version.versionUrl || "")

  gcloud pubsub subscriptions create ${PUBSUB_SUBSCRIPTION_NAME} \
    --topic=${TOPIC} \
    --push-auth-service-account=${PUBSUB_INVOKER}@${GCP_PROJECT}.iam.gserviceaccount.com\
    --push-endpoint="${app_service_url}/pubsub/send-email" \
    --ack-deadline=10 \
    --project=${GCP_PROJECT} ||
    fail "failed to create a Pub/Sub subscription"
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