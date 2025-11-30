#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status

# --- 1. Configuration Setup ---

# Check if configuration file exists
if [ ! -f .gcpenv ]; then
    echo "Error: Configuration file '.gcpenv' not found."
    echo "Please copy 'sample_vars.sh' to '.gcpenv' and update values."
    exit 1
fi

# Load environment variables
source .gcpenv

# Ensure gcloud uses the correct project ID from config
gcloud config set project "$PROJECT_ID"

# Prevent envsubst from replacing $COMMIT_SHA (needed for Cloud Build)
export COMMIT_SHA='$COMMIT_SHA'

echo "--- Generating Configuration Files from Templates ---"
mkdir -p k8s

# Generate Kubernetes manifests from templates
envsubst < templates/deployment.yaml > k8s/deployment.yaml
envsubst < templates/service.yaml > k8s/service.yaml
envsubst < templates/ingress.yaml > k8s/ingress.yaml

# Generate Cloud Build configuration
envsubst < templates/cloudbuild.yaml > cloudbuild.yaml

echo "--- Configuration generated in k8s/ and cloudbuild.yaml ---"

echo "--- Setting up GCP Infrastructure ---"

# Enable required GCP APIs
gcloud services enable artifactregistry.googleapis.com \
    container.googleapis.com \
    cloudbuild.googleapis.com \
    sqladmin.googleapis.com \
    secretmanager.googleapis.com

# 1. Network & Static IP
if ! gcloud compute addresses describe "$STATIC_IP_NAME" --global > /dev/null 2>&1; then
    echo "Creating Static IP: $STATIC_IP_NAME..."
    gcloud compute addresses create "$STATIC_IP_NAME" --global
else
    echo "Static IP $STATIC_IP_NAME already exists. Skipping."
fi

# 2. Artifact Registry
if ! gcloud artifacts repositories describe "$REPO_NAME" --location="$REGION" > /dev/null 2>&1; then
    echo "Creating Artifact Registry: $REPO_NAME..."
    gcloud artifacts repositories create "$REPO_NAME" --repository-format=docker --location="$REGION"
else
    echo "Repository $REPO_NAME already exists. Skipping."
fi

# 3. Secret Manager (Database Password)
if ! gcloud secrets describe sql-password > /dev/null 2>&1; then
    echo "Creating Secret: sql-password..."
    printf "$DB_PASS" | gcloud secrets create sql-password --data-file=-
else
    echo "Secret sql-password already exists. Skipping."
fi

# 4. Cloud SQL (This takes 5-10 minutes)
if ! gcloud sql instances describe "$SQL_INSTANCE_NAME" > /dev/null 2>&1; then
    echo "Creating Cloud SQL Instance: $SQL_INSTANCE_NAME (this may take a while)..."
    gcloud sql instances create "$SQL_INSTANCE_NAME" \
        --database-version=POSTGRES_13 \
        --cpu=1 --memory=4GB \
        --region="$REGION" \
        --root-password="$DB_PASS" \
        --availability-type=ZONAL
    
    echo "Creating Database and User..."
    gcloud sql databases create "$DB_NAME" --instance="$SQL_INSTANCE_NAME"
    gcloud sql users create "$DB_USER" --instance="$SQL_INSTANCE_NAME" --password="$DB_PASS"
else
    echo "Cloud SQL Instance $SQL_INSTANCE_NAME already exists. Skipping."
fi

# 5. GKE Cluster
if ! gcloud container clusters describe "$CLUSTER_NAME" --zone "$ZONE" > /dev/null 2>&1; then
    echo "Creating GKE Cluster: $CLUSTER_NAME..."
    gcloud container clusters create "$CLUSTER_NAME" \
        --zone "$ZONE" \
        --num-nodes 1 \
        --scopes=cloud-platform
else
    echo "GKE Cluster $CLUSTER_NAME already exists. Skipping."
fi

# --- Kubernetes Configuration ---

echo "--- Configuring Kubernetes ---"
# Get credentials for kubectl
gcloud container clusters get-credentials "$CLUSTER_NAME" --zone "$ZONE"

# Create/Update secret inside K8s
# (Using dry-run allows this command to run safely even if secret exists)
kubectl create secret generic db-credentials \
    --from-literal=database_url="postgresql://${DB_USER}:${DB_PASS}@127.0.0.1:5432/${DB_NAME}" \
    --dry-run=client -o yaml | kubectl apply -f -

# --- IAM Permissions ---

echo "--- Configuring IAM Permissions for Cloud Build ---"
# Get Project Number (required for Service Account email)
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
CB_SA="serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"

# 1. Allow reading secrets (to access DB password)
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="$CB_SA" \
    --role=roles/secretmanager.secretAccessor > /dev/null

# 2. Allow Cloud SQL connection (for migrations)
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="$CB_SA" \
    --role=roles/cloudsql.client > /dev/null

# 3. Allow GKE deployment (for kubectl apply)
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="$CB_SA" \
    --role=roles/container.developer > /dev/null

echo "--- Infrastructure Setup Complete ---"