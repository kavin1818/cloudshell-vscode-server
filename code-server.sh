#!/bin/bash

PASSWORD="mysecurepassword123"
PORT="8080"

# -------------------------------------------------------
# Get target folder
# -------------------------------------------------------
FOLDER="${1:-$(pwd)}"
FOLDER="$(realpath "$FOLDER")"

if [ ! -d "$FOLDER" ]; then
    echo "❌ Folder does not exist: $FOLDER"
    exit 1
fi

# -------------------------------------------------------
# Configure code-server
# -------------------------------------------------------
mkdir -p "$HOME/.config/code-server"

cat > "$HOME/.config/code-server/config.yaml" <<EOF
bind-addr: 0.0.0.0:${PORT}
auth: password
password: ${PASSWORD}
cert: false
EOF

# -------------------------------------------------------
# Stop existing code-server
# -------------------------------------------------------
pkill -x code-server 2>/dev/null || true
sleep 2

# -------------------------------------------------------
# Start code-server in the requested folder
# -------------------------------------------------------
nohup code-server \
    --bind-addr "0.0.0.0:${PORT}" \
    --auth password \
    --user-data-dir "$HOME/.local/share/code-server-session" \
    "$FOLDER" \
    > "$HOME/code-server.log" 2>&1 &

echo "✅ code-server started"
echo "📁 Folder: $FOLDER"
echo "🌐 Port: $PORT"
echo "🔑 Password: $PASSWORD"
echo "📄 Log: $HOME/code-server.log"