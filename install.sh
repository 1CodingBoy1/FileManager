#!/bin/bash
set -e

INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_PATH="/usr/local/bin/vps-fm"

echo ""
echo "  ╔══════════════════════════════════════════╗"
echo "  ║   VPS File Manager - Made By CodingBoyz  ║"
echo "  ╚══════════════════════════════════════════╝"
echo ""
echo "  Source: $INSTALL_DIR"
echo ""

if ! command -v python3 &> /dev/null; then
    echo "  [+] Python3 not found. Installing..."
    if command -v apt-get &> /dev/null; then
        apt-get update -qq && apt-get install -y -qq python3
    elif command -v yum &> /dev/null; then
        yum install -y -q python3
    elif command -v apk &> /dev/null; then
        apk add --quiet python3
    elif command -v dnf &> /dev/null; then
        dnf install -y -q python3
    else
        echo "  [!] Cannot auto-install Python3. Install it manually and re-run."
        exit 1
    fi
    echo "  [✓] Python3 installed."
else
    echo "  [✓] Python3 found: $(python3 --version)"
fi

if [ ! -f "$INSTALL_DIR/server.py" ]; then
    echo "  [!] server.py not found in $INSTALL_DIR"
    exit 1
fi

if [ ! -f "$INSTALL_DIR/index.html" ]; then
    echo "  [!] index.html not found in $INSTALL_DIR"
    exit 1
fi

chmod +x "$INSTALL_DIR/start"
chmod +x "$INSTALL_DIR/server.py"

ln -sf "$INSTALL_DIR/start" "$BIN_PATH"

echo "  [✓] Linked start command to $BIN_PATH"
echo ""
echo "  Done! Usage:"
echo "    vps-fm              # Start on port 8080"
echo "    vps-fm 3000         # Start on port 3000"
echo "    vps-fm 8080 0.0.0.0 # Start on port 8080, all interfaces"
echo ""
echo "  Open http://<your-vps-ip>:8080 in your browser."
echo ""
