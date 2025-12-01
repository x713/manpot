#!/bin/bash

# Load configuration
if [ ! -f .gcpenv ]; then
    echo "Error: .gcpenv not found."
    exit 1
fi
set -a
source .gcpenv
set +a

echo "======================================================"
echo "WARNING: YOU ARE ABOUT TO DELETE ALL INFRASTRUCTURE"
echo "Project: $PROJECT_ID"
echo "Cluster: $CLUSTER_NAME"
echo "Database: $SQL_INSTANCE_NAME"
echo "======================================================"
read -p "Are you sure you want to proceed? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cleanup cancelled."
    exit 1
fi

gcloud config set project "$PROJECT_ID"

# --- 1. IAM Cleanups ---
echo "--- Removing IAM Bindings ---"
P_NUM=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
SAs=("serviceAccount:${P_NUM}@cloudbuild.gserviceaccount.com" "serviceAccount:${P_NUM}-compute@developer.gserviceaccount.com")

for SA in "${SAs[@]}"; do
    echo "Revoking roles for $SA..."
    # We use || true to prevent the script from stopping if the binding is already gone
    gcloud projects remove-iam-policy-binding "$PROJECT_ID" --member="$SA" --role="roles/secretmanager.secretAccessor" --quiet > /dev/null 2>&1 || true
    gcloud projects remove-iam-policy-binding "$PROJECT_ID" --member="$SA" --role="roles/cloudsql.client" --quiet > /dev/null 2>&1 || true
    gcloud projects remove-iam-policy-binding "$PROJECT_ID" --member="$SA" --role="roles/container.developer" --quiet > /dev/null 2>&1 || true
done

# --- 2. GKE Cluster ---
echo "--- Deleting GKE Cluster (This takes time) ---"
if gcloud container clusters describe "$CLUSTER_NAME" --zone "$ZONE" > /dev/null 2>&1; then
    gcloud container clusters delete "$CLUSTER_NAME" --zone "$ZONE" --quiet
    echo "Cluster deleted."
else
    echo "Cluster not found, skipping."
fi

# --- 3. Cloud SQL ---
echo "--- Deleting Cloud SQL Instance ---"
if gcloud sql instances describe "$SQL_INSTANCE_NAME" > /dev/null 2>&1; then
    gcloud sql instances delete "$SQL_INSTANCE_NAME" --quiet
    echo "SQL Instance deleted."
else
    echo "SQL Instance not found, skipping."
fi

# --- 4. Secrets ---
echo "--- Deleting Secrets ---"
SECRETS=("sql-password" "sql-user" "sql-db")
for SEC in "${SECRETS[@]}"; do
    if gcloud secrets describe "$SEC" > /dev/null 2>&1; then
        gcloud secrets delete "$SEC" --quiet
        echo "Deleted secret: $SEC"
    fi
done

# --- 5. Artifact Registry ---
echo "--- Deleting Artifact Registry ---"
if gcloud artifacts repositories describe "$REPO_NAME" --location="$REGION" > /dev/null 2>&1; then
    gcloud artifacts repositories delete "$REPO_NAME" --location="$REGION" --quiet
    echo "Repository deleted."
else
    echo "Repository not found, skipping."
fi

# --- 6. Static IP ---
echo "--- Deleting Static IP ---"
if gcloud compute addresses describe "$STATIC_IP_NAME" --global > /dev/null 2>&1; then
    gcloud compute addresses delete "$STATIC_IP_NAME" --global --quiet
    echo "Static IP released."
fi

# --- 7. Local Files ---
echo "--- Cleaning up local generated files ---"
rm -f cloudbuild.yaml
rm -rf k8s/

# Note: We KEEP migrate.sh and wait_for_db.py because those are now part of your source code/repo.

# --- 8. VPC Peering (Optional/Aggressive) ---
# Removing the allocated IP range is often tricky because it stays in "deleting" state for a while.
# We will attempt to remove the range, but ignore errors if it's still in use.
echo "--- Attempting to release Private Service Access IP range ---"
gcloud compute addresses delete google-managed-services-default --global --quiet > /dev/null 2>&1 || echo "Could not delete VPC range (it might still be releasing). This is normal."

echo "======================================================"
echo "Cleanup Complete! You are ready to start from scratch."
echo "======================================================"
