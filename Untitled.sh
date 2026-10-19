#!/bin/bash
set -e

# Configuration
JDK="$HOME/jdks/jdk-25.jdk/Contents/Home"
SERVER="$HOME/Desktop/Tarnish/SwiftFUP/server/build/install/server/bin/server"
PROJECT="$HOME/Desktop/GaryOSRS.xcodeproj"

# Configure Java
export JAVA_HOME="$JDK"
export PATH="$JAVA_HOME/bin:$PATH"

echo "======================================"
echo " GaryOSRS — Build Preparation"
echo "======================================"

# 1. Check Java
echo ""
echo "Checking Java 25..."

if [ ! -x "$JDK/bin/java" ]; then
    echo "ERROR: Java not found at:"
    echo "$JDK/bin/java"
    exit 1
fi

"$JDK/bin/java" -version

# 2. Verify server executable
echo ""
echo "Checking server executable..."

if [ ! -x "$SERVER" ]; then
    echo "ERROR: Server executable not found:"
    echo "$SERVER"
    exit 1
fi

# 3. Refresh cache
echo ""
echo "Refreshing RuneScape cache..."

"$SERVER" cache

echo "Cache refresh complete."

# 4. Open Xcode project
echo ""
echo "Opening GaryOSRS in Xcode..."

if [ -d "$PROJECT" ]; then
    open "$PROJECT"
else
    echo "ERROR: Xcode project not found:"
    echo "$PROJECT"
    exit 1
fi

# 5. Finish
echo ""
echo "======================================"
echo " Preparation complete!"
echo "======================================"
echo ""
echo "In Xcode, press Cmd+R to run GaryOSRS."