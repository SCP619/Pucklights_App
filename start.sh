#!/bin/bash
# PuckLights – start backend + Cloudflare tunnel
cd "$(dirname "$0")"

# Aktivoi virtuaaliympäristö (.venv)
if [ -f "venv/Scripts/activate" ]; then
    source venv/Scripts/activate
    echo "✅ Activated venv"
else
    echo "❌ .venv not found — please create venv first"
    exit 1
fi

# Kill anything already on port 8000
fuser -k 8000/tcp 2>/dev/null
sleep 1

echo "Starting backend..."
# Käytetään suoraan uvicornia venv:in pythonilla, ei uv run
nohup venv/Scripts/python.exe -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/pucklights-backend.log 2>&1 &
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