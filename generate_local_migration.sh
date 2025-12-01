#!/bin/bash
set -e

# 1. Load Config
if [ ! -f .gcpenv ]; then
    echo "Error: .gcpenv not found."
    exit 1
fi
set -a
source .gcpenv
set +a

echo "--- [generate_local_migration.sh] Generating Migration File ---"

# 2. Setup Proxy (The helper to connect local Flask to Cloud SQL)
PROXY_BIN="./cloud-sql-proxy"
if [ ! -f "$PROXY_BIN" ]; then
    echo "Downloading Cloud SQL Proxy..."
    wget -q https://storage.googleapis.com/cloud-sql-connectors/cloud-sql-proxy/v2.14.0/cloud-sql-proxy.linux.amd64 -O "$PROXY_BIN"
    chmod +x "$PROXY_BIN"
fi

echo "Fetching Instance Connection Name..."
CONN_NAME=$(gcloud sql instances describe $SQL_INSTANCE_NAME --format="value(connectionName)")

echo "Starting Proxy for $CONN_NAME..."
# Start in background
./cloud-sql-proxy $CONN_NAME --port=5432 > proxy.log 2>&1 &
PROXY_PID=$!

echo "Waiting for Proxy to accept connections..."
for i in {1..30}; do
    if (echo > /dev/tcp/127.0.0.1/5432) >/dev/null 2>&1; then
        echo "Proxy is Ready!"
        break
    fi
    sleep 1
done

# 3. Configure Local Environment
# Override the URL to use localhost for this script only
export DATABASE_URL="postgresql://$DB_USER:$DB_PASS@127.0.0.1:5432/$DB_NAME"

# 4. Generate Files
echo "--- Initializing Migrations ---"
if [ ! -d "migrations" ]; then
    flask db init
fi

echo "--- Generating Migration Script ---"
# This connects to the DB, checks the schema, and creates the python file
flask db migrate -m "Initial structure and data"

# 5. Cleanup
echo "--- Stopping Proxy ---"
kill $PROXY_PID 2>/dev/null || true

# 6. Instructions
echo "=========================================================="
echo "Migration file generated successfully!"
echo "Now perform Step 3.2 from your README:"
echo "1. Go to migrations/versions/"
echo "2. Open the new .py file"
echo "3. Add your op.execute commands inside 'def upgrade():'"
echo "=========================================================="
