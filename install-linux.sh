#!/bin/sh
# Claude Codex Battery — Linux/Chromebook (Crostini) setup.
# Registers a background server (systemd user service) and a launcher entry, so the
# battery window opens from the ChromeOS launcher like a regular app.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
BUN="$(command -v bun || echo "$HOME/.bun/bin/bun")"
if [ ! -x "$BUN" ]; then
  echo "bun not found — install it first:  curl -fsSL https://bun.sh/install | bash"
  exit 1
fi

echo "🔧 Installing background server (systemd user service)…"
mkdir -p "$HOME/.config/systemd/user"
cat > "$HOME/.config/systemd/user/ccb-serve.service" <<UNIT
[Unit]
Description=Claude Codex Battery window server

[Service]
ExecStart=$BUN $DIR/claude-codex-usage.2m.js --serve
Restart=on-failure

[Install]
WantedBy=default.target
UNIT
systemctl --user daemon-reload
systemctl --user enable --now ccb-serve.service

echo "🚀 Registering launcher entry…"
mkdir -p "$HOME/.local/share/applications"
cat > "$HOME/.local/share/applications/ccb.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Claude Codex Battery
Comment=Claude Code & Codex usage batteries
Exec=sh -c "systemctl --user start ccb-serve.service; sleep 1; garcon-url-handler http://localhost:41414 || xdg-open http://localhost:41414"
Icon=$DIR/docs/app-icon.png
Terminal=false
Categories=Development;Utility;
DESKTOP
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true

echo "✅ Done. 'Claude Codex Battery' now appears in your launcher (Linux apps)."
echo "   Click it to open the battery window; the server keeps running in the background."
echo "   Tip: in Chrome, ⋮ → Save and share → Install page as app for a standalone window."
