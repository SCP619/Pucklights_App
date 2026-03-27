#!/bin/bash
# PuckLights – start backend + Cloudflare tunnel
cd "$(dirname "$0")"

# Kill anything already on port 8000
fuser -k 8000/tcp 2>/dev/null
sleep 1

echo "Starting backend..."
nohup uv run uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/pucklights-backend.log 2>&1 &
echo "Backend PID: $!"

sleep 3
if ss -tlnp | grep -q 8000; then
    echo "✅ Backend running on port 8000"
else
    echo "❌ Backend failed to start — check /tmp/pucklights-backend.log"
    exit 1
fi

echo ""
echo "Starting Cloudflare tunnel..."
echo "⚠️  Copy the trycloudflare.com URL below into the app settings."
echo ""
cloudflared tunnel --url http://localhost:8000
