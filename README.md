# hockey_highlights


# ~/start-pucklights.sh
cd ~/LDB/App
uv run uvicorn main:app --host 0.0.0.0 --port 8000 &
cloudflared tunnel --url http://localhost:8000
