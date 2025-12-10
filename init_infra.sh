#!/bin/bash
set -e

# --- 1. Load Config ---
if [ ! -f .gcpenv ]; then
    echo "Error: .gcpenv not found."
    exit 1
fi
set -a
source .gcpenv
set +a

# Ensure PROJECT_ID is valid
if [ -z "$PROJECT_ID" ]; then
    PROJECT_ID=$(gcloud config get-value project)
fi
gcloud config set project "$PROJECT_ID"

# --- Infrastructure Setup ---
echo "--- Enabling APIs (this may take a moment) ---"
gcloud services enable \
    artifactregistry.googleapis.com \
    container.googleapis.com \
    cloudbuild.googleapis.com \
    sqladmin.googleapis.com \
    secretmanager.googleapis.com \
    servicenetworking.googleapis.com

echo "--- Network Setup (Private IP) ---"
if ! gcloud compute addresses describe google-managed-services-default --global > /dev/null 2>&1; then
    gcloud compute addresses create google-managed-services-default --global --purpose=VPC_PEERING --prefix-length=16 --network=default --verbosity=none
fi
if ! gcloud services vpc-peerings describe servicenetworking-googleapis-com --network=default > /dev/null 2>&1; then
    gcloud services vpc-peerings connect --service=servicenetworking.googleapis.com --ranges=google-managed-services-default --network=default --project=$PROJECT_ID
fi
if ! gcloud compute addresses describe "$STATIC_IP_NAME" --global > /dev/null 2>&1; then
    gcloud compute addresses create "$STATIC_IP_NAME" --global
fi

echo "--- Artifact Registry ---"
if ! gcloud artifacts repositories describe "$REPO_NAME" --location="$REGION" > /dev/null 2>&1; then
    gcloud artifacts repositories create "$REPO_NAME" --repository-format=docker --location="$REGION"
fi

echo "--- Creating Secrets ---"
# 1. Password
if ! gcloud secrets describe sql-password > /dev/null 2>&1; then
    printf "$DB_PASS" | gcloud secrets create sql-password --data-file=-
fi
# 2. User
if ! gcloud secrets describe sql-user > /dev/null 2>&1; then
    printf "$DB_USER" | gcloud secrets create sql-user --data-file=-
fi
# 3. DB Name
if ! gcloud secrets describe sql-db > /dev/null 2>&1; then
    printf "$DB_NAME" | gcloud secrets create sql-db --data-file=-
fi

echo "--- Cloud SQL Setup (Dual IP) ---"
if ! gcloud sql instances describe "$SQL_INSTANCE_NAME" > /dev/null 2>&1; then
    echo "    > Creating Cloud SQL instance (this takes ~10-15 mins)..."
    gcloud sql instances create "$SQL_INSTANCE_NAME" \
        --database-version=POSTGRES_13 \
        --cpu=1 --memory=4GB \
        --region="$REGION" \
        --root-password="$DB_PASS" \
        --availability-type=ZONAL \
        --network=default \
        --assign-ip 
        
    gcloud sql databases create "$DB_NAME" --instance="$SQL_INSTANCE_NAME"
    gcloud sql users create "$DB_USER" --instance="$SQL_INSTANCE_NAME" --password="$DB_PASS"
else
    echo "    > Instance exists. Verifying Public IP..."
    gcloud sql instances patch "$SQL_INSTANCE_NAME" --assign-ip --network=default
fi

echo "    > Ensuring database [$DB_NAME] and user [$DB_USER] exist..."

# Check and create Database
if ! gcloud sql databases describe "$DB_NAME" --instance="$SQL_INSTANCE_NAME" > /dev/null 2>&1; then
    echo "      > Creating database [$DB_NAME]..."
    gcloud sql databases create "$DB_NAME" --instance="$SQL_INSTANCE_NAME"
fi

# Check and create User
if ! gcloud sql users describe "$DB_USER" --instance="$SQL_INSTANCE_NAME" > /dev/null 2>&1; then
    echo "      > Creating user [$DB_USER]..."
    gcloud sql users create "$DB_USER" --instance="$SQL_INSTANCE_NAME" --password="$DB_PASS"
fi

echo "--- GKE Cluster ---"
if ! gcloud container clusters describe "$CLUSTER_NAME" --zone "$ZONE" > /dev/null 2>&1; then
    echo "    > Creating GKE Cluster (this takes ~5-10 mins)..."
    gcloud container clusters create "$CLUSTER_NAME" --zone "$ZONE" --num-nodes 1 --scopes=cloud-platform
fi

# --- 6. IAM Permissions ---
echo "--- Updating IAM ---"
P_NUM=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
SAs=("serviceAccount:${P_NUM}@cloudbuild.gserviceaccount.com" "serviceAccount:${P_NUM}-compute@developer.gserviceaccount.com")

for SA in "${SAs[@]}"; do
    gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="$SA" --role="roles/cloudsql.client" > /dev/null
    gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="$SA" --role="roles/secretmanager.secretAccessor" > /dev/null
    gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="$SA" --role="roles/container.developer" > /dev/null
done

# --- 7. K8s Secrets ---
echo "--- Applying K8s Secrets and Service Accounts ---"
gcloud container clusters get-credentials "$CLUSTER_NAME" --zone "$ZONE"

# Create Service Account for Workload Identity/Proxy
kubectl create serviceaccount $SERVICE_ACCOUNT_NAME --dry-run=client -o yaml | kubectl apply -f -

# Create DB Credentials Secret
kubectl create secret generic db-credentials \
    --from-literal=database_url="postgresql://${DB_USER}:${DB_PASS}@127.0.0.1:5432/${DB_NAME}" \
    --dry-run=client -o yaml | kubectl apply -f -

echo "=========================================="
echo " Setup Complete! Infrastructure is ready. "
echo "=========================================="