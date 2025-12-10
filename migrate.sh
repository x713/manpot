#!/bin/bash
set -e

# Configuration
PROXY_PORT=5432
PROXY_BIN="/tmp/cloud-sql-proxy"

# Check/Construct Connection Name
if [ -z "$INSTANCE_CONNECTION_NAME" ]; then
    if [ -n "$PROJECT_ID" ] && [ -n "$REGION" ] && [ -n "$SQL_INSTANCE_NAME" ]; then
        export INSTANCE_CONNECTION_NAME="${PROJECT_ID}:${REGION}:${SQL_INSTANCE_NAME}"
        echo "Auto-detected INSTANCE_CONNECTION_NAME: $INSTANCE_CONNECTION_NAME"
    else
        echo "Error: INSTANCE_CONNECTION_NAME is not set."
        echo "Please export it or source .gcpenv (ensure PROJECT_ID, REGION, SQL_INSTANCE_NAME are set)."
        exit 1
    fi
fi

echo "--- [migrate.sh] Starting Migration Wrapper ---"

# 1. Download Cloud SQL Proxy (if not present)
if [ ! -f "$PROXY_BIN" ]; then
    echo "Downloading Cloud SQL Proxy..."
    wget -q https://storage.googleapis.com/cloud-sql-connectors/cloud-sql-proxy/v2.14.0/cloud-sql-proxy.linux.amd64 -O "$PROXY_BIN"
    chmod +x "$PROXY_BIN"
fi

# 2. Start Proxy in Background
echo "Starting Proxy for: $INSTANCE_CONNECTION_NAME"
# We DO NOT use --private-ip here because Cloud Build is external
"$PROXY_BIN" "$INSTANCE_CONNECTION_NAME" --port=$PROXY_PORT > /tmp/proxy.log 2>&1 &
PROXY_PID=$!

# 3. Wait for Proxy to be Ready
echo "Waiting for localhost:$PROXY_PORT..."
TIMEOUT=30
ELAPSED=0
READY=false

while [ $ELAPSED -lt $TIMEOUT ]; do
    if (echo > /dev/tcp/127.0.0.1/$PROXY_PORT) >/dev/null 2>&1; then
        echo "Proxy is listening!"
        READY=true
        break
    fi
    sleep 1
    ELAPSED=$((ELAPSED+1))
done

if [ "$READY" = "false" ]; then
    echo "CRITICAL: Proxy failed to start within $TIMEOUT seconds."
    echo "--- Proxy Logs ---"
    cat /tmp/proxy.log
    exit 1
fi

# 4. Run Migration
echo "Running Flask DB Upgrade..."
# Construct the URL for localhost
export DATABASE_URL="postgresql://$DB_USER:$DB_PASS@127.0.0.1:$PROXY_PORT/$DB_NAME"

# Run the upgrade
if [ -d "/app" ]; then
    cd /app
fi

if flask db upgrade; then
    echo "Migration Successful!"
    EXIT_CODE=0
else
    echo "Migration Failed."
    EXIT_CODE=1
fi

# 5. Cleanup
echo "Stopping Proxy..."
kill $PROXY_PID 2>/dev/null || true
exit $EXIT_CODE
