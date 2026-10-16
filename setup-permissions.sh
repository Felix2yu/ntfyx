#!/bin/bash
set -e

echo "🔧 ntfyx Notification Permission Setup"
echo "==========================================="
echo ""

# Check if app bundle exists
if [ ! -d ".build/release/ntfyx.app" ]; then
    echo "❌ App bundle not found. Run './build-app.sh' first."
    exit 1
fi

echo "1. Resetting any previous permission state..."
tccutil reset UserNotifications im.yufei.ntfyx 2>/dev/null || true
# The app lived under com.laurentftech.ntfyx before the rename; drop the stale row too.
tccutil reset UserNotifications com.laurentftech.ntfyx 2>/dev/null || true

echo "2. Opening the app to trigger permission request..."
echo ""
echo "   👀 WATCH FOR THE PERMISSION DIALOG!"
echo "   It will ask: 'ntfyx Would Like to Send You Notifications'"
echo "   Click 'Allow' when it appears"
echo ""

# Launch the app and keep it running
open -W -a .build/release/ntfyx.app --args test-notify --topic test &
APP_PID=$!

echo ""
echo "3. Waiting for you to respond to the permission dialog..."
sleep 8

echo ""
echo "4. Checking System Settings..."
open "x-apple.systempreferences:com.apple.preference.notifications"

echo ""
echo "✅ System Settings → Notifications is now open"
echo ""
echo "   Please:"
echo "   1. Scroll down the left sidebar to find 'ntfyx'"
echo "   2. Click on it"
echo "   3. Toggle 'Allow Notifications' to ON"
echo ""
echo "Once you've done that, press Enter to continue..."
read

echo ""
echo "✅ Setup complete! Test with:"
echo "   .build/release/ntfyx.app/Contents/MacOS/ntfyx test-notify --topic test"
