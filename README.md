# hockey_highlights
##setup

pip install fastapi[all] python-multipart aiofiles ultralytics opencv-python

## Run backend 
uvicorn main:app --host 0.0.0.0 --port 8000

## Build Flutter app
flutter create . --project-name hockey_highlights
flutter pub get
flutter run

