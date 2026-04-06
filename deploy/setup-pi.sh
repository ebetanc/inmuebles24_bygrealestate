#!/usr/bin/env bash
# Setup script for Raspberry Pi 5 deployment
# Run as: sudo bash deploy/setup-pi.sh
set -euo pipefail

echo "=== Inmuebles24 Scraper — Pi 5 Setup ==="

# 1. System packages
echo "[1/6] Installing system packages..."
apt-get update -qq
apt-get install -y -qq python3 python3-venv python3-pip chromium-browser git

# 2. Create app directory
APP_DIR="/home/pi/inmuebles24"
echo "[2/6] Setting up app directory: $APP_DIR"
if [ ! -d "$APP_DIR" ]; then
    mkdir -p "$APP_DIR"
    chown pi:pi "$APP_DIR"
fi

# 3. Python venv
echo "[3/6] Creating Python virtual environment..."
sudo -u pi python3 -m venv "$APP_DIR/.venv"
sudo -u pi "$APP_DIR/.venv/bin/pip" install --upgrade pip -q

# 4. State directory
STATE_DIR="/home/pi/.inmuebles24"
echo "[4/6] Creating state directory: $STATE_DIR"
sudo -u pi mkdir -p "$STATE_DIR/fallback" "$STATE_DIR/logs"

# 5. Install systemd units
echo "[5/6] Installing systemd units..."
cp deploy/inmuebles24.service /etc/systemd/system/
cp deploy/inmuebles24.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable inmuebles24.timer

# 6. Reminder
echo "[6/6] Setup complete!"
echo ""
echo "Next steps:"
echo "  1. Clone repo to $APP_DIR and install:"
echo "     cd $APP_DIR && .venv/bin/pip install -e ."
echo "  2. Set Chrome path in .env:"
echo "     CHROME_PATH=/usr/bin/chromium-browser"
echo "  3. Create .env file:"
echo "     cp .env.example $APP_DIR/.env && chmod 600 $APP_DIR/.env"
echo "     nano $APP_DIR/.env  # fill in credentials"
echo "  4. Test manually:"
echo "     cd $APP_DIR && .venv/bin/python -m inmobiliaria24 --dry-run"
echo "  5. Start the timer:"
echo "     sudo systemctl start inmuebles24.timer"
echo "  6. Check status:"
echo "     systemctl status inmuebles24.timer"
echo "     journalctl -u inmuebles24.service -f"
