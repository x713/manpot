#!/bin/bash
set -e

# --- 1. Config ---
if [ ! -f .gcpenv ]; then
    echo "Error: .gcpenv not found."
    exit 1
fi
source .gcpenv
gcloud config set project "$PROJECT_ID"

# Prevent envsubst from replacing $COMMIT_SHA
export COMMIT_SHA='$COMMIT_SHA'

echo "--- Generating Configs ---"
mkdir -p k8s

# Simple generation. envsubst will ignore $$DB_PASS in cloudbuild.yaml
# but will replace ${DB_PASS} in deployment.yaml. Magic!
envsubst < templates/cloudbuild.yaml > cloudbuild.yaml
envsubst < templates/deployment.yaml > k8s/deployment.yaml
envsubst < templates/service.yaml > k8s/service.yaml
envsubst < templates/ingress.yaml > k8s/ingress.yaml

echo "--- Configs Generated ---"

# --- 2. Infrastructure (Idempotent) ---
echo "--- Checking Infrastructure ---"
gcloud services enable artifactregistry.googleapis.com container.googleapis.com cloudbuild.googleapis.com sqladmin.googleapis.com secretmanager.googleapis.com

# IP
if ! gcloud compute addresses describe "$STATIC_IP_NAME" --global > /dev/null 2>&1; then
    gcloud compute addresses create "$STATIC_IP_NAME" --global
fi

# Repo
if ! gcloud artifacts repositories describe "$REPO_NAME" --location="$REGION" > /dev/null 2>&1; then
    gcloud artifacts repositories create "$REPO_NAME" --repository-format=docker --location="$REGION"
fi

# Secret
if ! gcloud secrets describe sql-password > /dev/null 2>&1; then
    printf "$DB_PASS" | gcloud secrets create sql-password --data-file=-
fi

# SQL
if ! gcloud sql instances describe "$SQL_INSTANCE_NAME" > /dev/null 2>&1; then
    gcloud sql instances create "$SQL_INSTANCE_NAME" --database-version=POSTGRES_13 --cpu=1 --memory=4GB --region="$REGION" --root-password="$DB_PASS" --availability-type=ZONAL
    gcloud sql databases create "$DB_NAME" --instance="$SQL_INSTANCE_NAME"
    gcloud sql users create "$DB_USER" --instance="$SQL_INSTANCE_NAME" --password="$DB_PASS"
fi

# Cluster
if ! gcloud container clusters describe "$CLUSTER_NAME" --zone "$ZONE" > /dev/null 2>&1; then
    gcloud container clusters create "$CLUSTER_NAME" --zone "$ZONE" --num-nodes 1 --scopes=cloud-platform
fi

# K8s Secret
gcloud container clusters get-credentials "$CLUSTER_NAME" --zone "$ZONE"
kubectl create secret generic db-credentials \
    --from-literal=database_url="postgresql://${DB_USER}:${DB_PASS}@127.0.0.1:5432/${DB_NAME}" \
    --dry-run=client -o yaml | kubectl apply -f -

# --- 3. IAM Permissions ---
echo "--- Configuring IAM ---"
P_NUM=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
CB_SA="serviceAccount:${P_NUM}@cloudbuild.gserviceaccount.com"
COMPUTE_SA="serviceAccount:${P_NUM}-compute@developer.gserviceaccount.com"

for SA in $CB_SA $COMPUTE_SA; do
    gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="$SA" --role="roles/secretmanager.secretAccessor" > /dev/null
    gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="$SA" --role="roles/cloudsql.client" > /dev/null
    gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="$SA" --role="roles/container.developer" > /dev/null
done

echo "--- Setup Complete ---"