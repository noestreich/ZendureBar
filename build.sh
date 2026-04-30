#!/bin/bash
set -e
cd "$(dirname "$0")"

APP="ZendureBar.app"

echo "→ Kompiliere..."
swift build -c release

echo "→ Erstelle $APP Bundle..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp .build/release/ZendureBar "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"

echo ""
echo "✓ $APP wurde erstellt."
echo ""
echo "Starten:    open $APP"
echo "Autostart:  $APP in Systemeinstellungen → Allgemein → Anmeldeöbjekte ziehen"
