# BuildCrew mobile (Flutter, Android)

```bash
python3 tool/prepare_android.py      # generate + harden android/ (idempotent)
flutter pub get
flutter run                          # demo mode (no backend needed)
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8000   # against local API
```

Release builds are produced by `.github/workflows/android.yml` and published to GitHub Releases;
installed apps update themselves from there (see `lib/core/updater.dart`).

Install: download `BuildCrew.apk` from https://github.com/kritish-narula/BuildCrew/releases/latest
