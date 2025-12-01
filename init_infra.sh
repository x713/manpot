#!/bin/bash
set -e

# --- 1. Configuration Setup ---
if [ ! -f .gcpenv ]; then
    echo "Error: Configuration file '.gcpenv' not found."
    exit 1
fi
source .gcpenv
gcloud config set project "$PROJECT_ID"

echo "--- Generating Configuration Files ---"
mkdir -p k8s

# --- CRITICAL FIX: MASKING VARIABLES ---
# 1. Mask COMMIT_SHA so envsubst ignores it
export COMMIT_SHA='$COMMIT_SHA'

# 2. Mask DB_PASS so envsubst keeps '$$DB_PASS' literally in cloudbuild.yaml
# We save the real password to a temp variable
REAL_DB_PASS=$DB_PASS
# We want envsubst to replace ${DB_PASS} with literal $DB_PASS
export DB_PASS='$$DB_PASS'

# Generate Cloud Build (It will now have $$DB_PASS, which is safe)
envsubst < templates/cloudbuild.yaml > cloudbuild.yaml

# 3. Restore REAL password for K8s manifests and infrastructure
export DB_PASS=$REAL_DB_PASS

# Generate K8s files (They need the REAL password)
envsubst < templates/deployment.yaml > k8s/deployment.yaml
envsubst < templates/service.yaml > k8s/service.yaml
envsubst < templates/ingress.yaml > k8s/ingress.yaml

echo "--- Configs Generated ---"

echo "--- Infrastructure Setup (Idempotent) ---"
# Enable APIs
gcloud services enable artifactregistry.googleapis.com container.googleapis.com cloudbuild.googleapis.com sqladmin.googleapis.com secretmanager.googleapis.com

# Create Resources if missing
if ! gcloud compute addresses describe "$STATIC_IP_NAME" --global > /dev/null 2>&1; then
    gcloud compute addresses create "$STATIC_IP_NAME" --global
fi

if ! gcloud artifacts repositories describe "$REPO_NAME" --location="$REGION" > /dev/null 2>&1; then
    gcloud artifacts repositories create "$REPO_NAME" --repository-format=docker --location="$REGION"
fi

if ! gcloud secrets describe sql-password > /dev/null 2>&1; then
    printf "$DB_PASS" | gcloud secrets create sql-password --data-file=-
fi

if ! gcloud sql instances describe "$SQL_INSTANCE_NAME" > /dev/null 2>&1; then
    gcloud sql instances create "$SQL_INSTANCE_NAME" --database-version=POSTGRES_13 --cpu=1 --memory=4GB --region="$REGION" --root-password="$DB_PASS" --availability-type=ZONAL
    gcloud sql databases create "$DB_NAME" --instance="$SQL_INSTANCE_NAME"
    gcloud sql users create "$DB_USER" --instance="$SQL_INSTANCE_NAME" --password="$DB_PASS"
fi

if ! gcloud container clusters describe "$CLUSTER_NAME" --zone "$ZONE" > /dev/null 2>&1; then
    gcloud container clusters create "$CLUSTER_NAME" --zone "$ZONE" --num-nodes 1 --scopes=cloud-platform
fi

# K8s Secrets
gcloud container clusters get-credentials "$CLUSTER_NAME" --zone "$ZONE"
kubectl create secret generic db-credentials \
    --from-literal=database_url="postgresql://${DB_USER}:${DB_PASS}@127.0.0.1:5432/${DB_NAME}" \
    --dry-run=client -o yaml | kubectl apply -f -

# IAM Permissions
P_NUM=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
# Add both default Cloud Build SA and Compute SA just in case
SAs=("serviceAccount:${P_NUM}@cloudbuild.gserviceaccount.com" "serviceAccount:${P_NUM}-compute@developer.gserviceaccount.com")

for SA in "${SAs[@]}"; do
    gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="$SA" --role="roles/secretmanager.secretAccessor" > /dev/null
    gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="$SA" --role="roles/cloudsql.client" > /dev/null
    gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="$SA" --role="roles/container.developer" > /dev/null
done

echo "--- Setup Complete ---"