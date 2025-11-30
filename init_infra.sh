#!/bin/bash
set -e # Stop if error

# 1. read config - check sample_vars.sh
#source sample_vars.sh
source .gcpenv

echo "--- Generating Configuration Files from Templates ---"
mkdir -p k8s
# create workfiles from templates  
envsubst < templates/deployment.yaml > k8s/deployment.yaml
envsubst < templates/service.yaml > k8s/service.yaml
envsubst < templates/ingress.yaml > k8s/ingress.yaml
# generate cloudbuild 
envsubst < templates/cloudbuild.yaml > cloudbuild.yaml

echo "--- Configuration generated in k8s/ and cloudbuild.yaml ---"

echo "--- Setting up GCP Infrastructure ---"
# Enable API
gcloud services enable artifactregistry.googleapis.com container.googleapis.com cloudbuild.googleapis.com sqladmin.googleapis.com secretmanager.googleapis.com

# Network и IP
if ! gcloud compute addresses describe $STATIC_IP_NAME --global > /dev/null 2>&1; then
    gcloud compute addresses create $STATIC_IP_NAME --global
fi

# Artifact Registry
if ! gcloud artifacts repositories describe $REPO_NAME --location=$REGION > /dev/null 2>&1; then
    gcloud artifacts repositories create $REPO_NAME --repository-format=docker --location=$REGION
fi

# Secret Manager
if ! gcloud secrets describe sql-password > /dev/null 2>&1; then
    printf $DB_PASS | gcloud secrets create sql-password --data-file=-
fi

# Cloud SQL (Takes time 5-10 minutes, skip if already done)
if ! gcloud sql instances describe $SQL_INSTANCE_NAME > /dev/null 2>&1; then
    gcloud sql instances create $SQL_INSTANCE_NAME --database-version=POSTGRES_13 --cpu=1 --memory=4GB --region=$REGION --root-password=$DB_PASS --availability-type=ZONAL
    gcloud sql databases create $DB_NAME --instance=$SQL_INSTANCE_NAME
    gcloud sql users create $DB_USER --instance=$SQL_INSTANCE_NAME --password=$DB_PASS
fi

# GKE Cluster
if ! gcloud container clusters describe $CLUSTER_NAME --zone $ZONE > /dev/null 2>&1; then
    gcloud container clusters create $CLUSTER_NAME --zone $ZONE --num-nodes 1 --scopes=cloud-platform
fi

# Get credentials for kubectl
gcloud container clusters get-credentials $CLUSTER_NAME --zone $ZONE

# Create secret inside K8s
kubectl create secret generic db-credentials \
    --from-literal=database_url="postgresql://${DB_USER}:${DB_PASS}@127.0.0.1:5432/${DB_NAME}" \
    --dry-run=client -o yaml | kubectl apply -f -

echo "--- Infrastructure Setup Complete ---"
