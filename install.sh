#!/bin/bash
# Linux Whisper Dictation - Install & Setup Script

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "========================================"
echo "  Linux Whisper Dictation - Installer"
echo "========================================"
echo ""

# ---- Check Python ----
if ! command -v python3 &> /dev/null; then
    echo "[ERROR] Python3 is required but not installed."
    exit 1
fi
echo "[OK] Python3 found: $(python3 --version)"

# ---- Check/install system dependencies ----
MISSING_PKGS=()

if ! command -v ydotool &> /dev/null; then
    MISSING_PKGS+=(ydotool)
fi

if ! command -v xdotool &> /dev/null; then
    MISSING_PKGS+=(xdotool)
fi

if ! command -v xclip &> /dev/null; then
    MISSING_PKGS+=(xclip)
fi

if ! command -v wl-copy &> /dev/null; then
    MISSING_PKGS+=(wl-clipboard)
fi

if ! command -v wtype &> /dev/null; then
    MISSING_PKGS+=(wtype)
fi

if ! dpkg -l | grep -q portaudio19-dev 2>/dev/null; then
    MISSING_PKGS+=(portaudio19-dev)
fi

if ! command -v ffmpeg &> /dev/null; then
    MISSING_PKGS+=(ffmpeg)
fi

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    echo "[SETUP] Installing system packages: ${MISSING_PKGS[*]}"
    sudo apt install -y "${MISSING_PKGS[@]}"
    echo ""
fi

echo "[OK] System dependencies installed"

# ---- Setup input group and uinput permissions ----
echo ""
echo "[SETUP] Configuring permissions for ydotool and evdev..."

# Add user to input group if not already a member
if ! id -nG "$USER" | grep -qw input; then
    echo "[SETUP] Adding $USER to 'input' group..."
    sudo usermod -aG input "$USER"
    NEEDS_RELOGIN=true
    echo "[OK] Added to input group (requires logout/login to take effect)"
else
    echo "[OK] Already in 'input' group"
fi

# Create udev rule for /dev/uinput
UINPUT_RULE="/etc/udev/rules.d/99-uinput.rules"
if [ ! -f "$UINPUT_RULE" ]; then
    echo "[SETUP] Creating udev rule for /dev/uinput..."
    echo 'KERNEL=="uinput", MODE="0660", GROUP="input"' | sudo tee "$UINPUT_RULE" > /dev/null
    sudo udevadm control --reload-rules
    sudo udevadm trigger
    echo "[OK] udev rule created"
else
    echo "[OK] udev rule already exists"
fi

# Ensure uinput module is loaded
if ! lsmod | grep -q uinput; then
    echo "[SETUP] Loading uinput kernel module..."
    sudo modprobe uinput
fi

# Ensure uinput loads on boot
if ! grep -q "^uinput$" /etc/modules-load.d/*.conf 2>/dev/null; then
    echo "uinput" | sudo tee /etc/modules-load.d/uinput.conf > /dev/null
    echo "[OK] uinput set to load on boot"
fi

# ---- Setup ydotoold systemd user service (only for ydotool v1.x+) ----
echo ""
echo "[SETUP] Checking ydotool version..."

YDOTOOL_SERVICE_DIR="$HOME/.config/systemd/user"
YDOTOOL_SERVICE="$YDOTOOL_SERVICE_DIR/ydotoold.service"

if command -v ydotoold &> /dev/null; then
    # ydotool v1.x+ has a separate daemon
    mkdir -p "$YDOTOOL_SERVICE_DIR"

    if [ ! -f "$YDOTOOL_SERVICE" ]; then
        cat > "$YDOTOOL_SERVICE" << 'EOF'
[Unit]
Description=ydotool daemon (user)
Documentation=man:ydotoold(8)

[Service]
ExecStart=/usr/bin/ydotoold
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF
        echo "[OK] Created ydotoold user service"
    else
        echo "[OK] ydotoold service already exists"
    fi

    systemctl --user daemon-reload

    if systemctl --user enable ydotoold.service 2>/dev/null; then
        echo "[OK] ydotoold service enabled"
    fi

    if systemctl --user start ydotoold.service 2>/dev/null; then
        echo "[OK] ydotoold service started"
    else
        echo "[WARN] Could not start ydotoold now (may need logout/login for group permissions)"
    fi
else
    # ydotool v0.1.x works without a daemon
    echo "[OK] ydotool v0.1.x detected (no daemon needed)"

    # Clean up any stale ydotoold service from a previous install
    if [ -f "$YDOTOOL_SERVICE" ]; then
        systemctl --user stop ydotoold.service 2>/dev/null || true
        systemctl --user disable ydotoold.service 2>/dev/null || true
        rm -f "$YDOTOOL_SERVICE"
        systemctl --user daemon-reload
        echo "[OK] Removed stale ydotoold service"
    fi
fi

# ---- Create Python venv ----
echo ""
echo "[SETUP] Creating virtual environment..."
python3 -m venv venv

echo "[SETUP] Installing Python dependencies..."
source venv/bin/activate
pip install --upgrade pip -q
pip install -r requirements.txt

# ---- GNOME autostart: import display env into systemd user session ----
echo ""
echo "[SETUP] Configuring display environment autostart..."

AUTOSTART_DIR="$HOME/.config/autostart"
AUTOSTART_FILE="$AUTOSTART_DIR/systemd-import-display.desktop"

mkdir -p "$AUTOSTART_DIR"
cat > "$AUTOSTART_FILE" << 'EOF'
[Desktop Entry]
Type=Application
Name=Import display env to systemd
Exec=systemctl --user import-environment DISPLAY XAUTHORITY XDG_SESSION_TYPE
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF
echo "[OK] Created display environment autostart"

# Import into current session immediately
systemctl --user import-environment DISPLAY XAUTHORITY XDG_SESSION_TYPE 2>/dev/null || true

# ---- Setup whisper-dictate systemd user service ----
echo ""
echo "[SETUP] Configuring whisper-dictate service..."

WHISPER_SERVICE_DIR="$HOME/.config/systemd/user"
WHISPER_SERVICE="$WHISPER_SERVICE_DIR/whisper-dictate.service"

mkdir -p "$WHISPER_SERVICE_DIR"

cat > "$WHISPER_SERVICE" << EOF
[Unit]
Description=Linux Whisper Dictation

[Service]
Type=simple
WorkingDirectory=$SCRIPT_DIR
ExecStart=$SCRIPT_DIR/venv/bin/python $SCRIPT_DIR/whisper_dictate.py
Restart=on-failure
RestartSec=5
TimeoutStartSec=120
StandardOutput=journal
StandardError=journal
Environment="PULSE_PROP_media.role=music"

[Install]
WantedBy=default.target
EOF
echo "[OK] Created whisper-dictate user service"

systemctl --user daemon-reload

if systemctl --user enable whisper-dictate.service 2>/dev/null; then
    echo "[OK] whisper-dictate service enabled"
fi

if systemctl --user start whisper-dictate.service 2>/dev/null; then
    echo "[OK] whisper-dictate service started"
else
    echo "[WARN] Could not start whisper-dictate now (may need logout/login for group permissions)"
fi

echo ""
echo "========================================"
echo "  Installation Complete!"
echo "========================================"
echo ""

if [ "$NEEDS_RELOGIN" = true ]; then
    echo "  IMPORTANT: You were added to the 'input' group."
    echo "  You MUST log out and log back in for this to take effect."
    echo ""
fi

echo "  The whisper-dictate service is installed and will auto-start on login."
echo ""
echo "  Useful commands:"
echo "    systemctl --user status whisper-dictate    # Check status"
echo "    systemctl --user restart whisper-dictate   # Restart"
echo "    systemctl --user stop whisper-dictate      # Stop"
echo "    journalctl --user -u whisper-dictate -f    # View logs"
echo ""
echo "  To run manually instead (stop the service first):"
echo "    systemctl --user stop whisper-dictate"
echo "    ./run.sh"
echo ""
