#!/bin/bash

# ServerDock Agent Installer
# This script installs the ServerDock agent on a Linux system

set -e

AGENT_VERSION="1.0.0"
BACKEND_URL="${SERVERDOCK_BACKEND_URL:-wss://api.serverdock.com}"
BOOTSTRAP_TOKEN="${SERVERDOCK_BOOTSTRAP_TOKEN}"
SERVER_ID="${SERVERDOCK_SERVER_ID}"
SERVER_SECRET="${SERVERDOCK_SERVER_SECRET}"
INSTALL_DIR="/opt/serverdock"
SERVICE_NAME="serverdock-agent"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --token)
            BOOTSTRAP_TOKEN="$2"
            shift 2
            ;;
        --server-id)
            SERVER_ID="$2"
            shift 2
            ;;
        --server-secret)
            SERVER_SECRET="$2"
            shift 2
            ;;
        --backend-url)
            BACKEND_URL="$2"
            shift 2
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Usage: $0 [--token TOKEN] [--server-id ID] [--server-secret SECRET] [--backend-url URL]"
            exit 1
            ;;
    esac
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Detect OS and architecture
detect_system() {
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)
    
    case $ARCH in
        x86_64)
            ARCH="amd64"
            ;;
        aarch64|arm64)
            ARCH="arm64"
            ;;
        *)
            echo -e "${RED}Unsupported architecture: $ARCH${NC}"
            exit 1
            ;;
    esac
    
    if [ "$OS" != "linux" ]; then
        echo -e "${RED}This installer only supports Linux${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}Detected system: $OS/$ARCH${NC}"
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Please run as root (use sudo)${NC}"
        exit 1
    fi
}

# Download agent binary
download_agent() {
    echo -e "${YELLOW}Downloading ServerDock agent...${NC}"
    
    BINARY_URL="${BACKEND_URL}/agent/download/${OS}/${ARCH}"
    
    mkdir -p "$INSTALL_DIR"
    curl -L -o "$INSTALL_DIR/serverdock-agent" "$BINARY_URL" || {
        echo -e "${RED}Failed to download agent binary${NC}"
        exit 1
    }
    
    chmod +x "$INSTALL_DIR/serverdock-agent"
    echo -e "${GREEN}Agent binary downloaded${NC}"
}

# Create systemd service
create_service() {
    echo -e "${YELLOW}Creating systemd service...${NC}"
    
    if [ -z "$BOOTSTRAP_TOKEN" ]; then
        echo -e "${RED}Bootstrap token is required (use --token or SERVERDOCK_BOOTSTRAP_TOKEN env var)${NC}"
        exit 1
    fi
    
    if [ -z "$SERVER_ID" ]; then
        echo -e "${RED}Server ID is required (use --server-id or SERVERDOCK_SERVER_ID env var)${NC}"
        exit 1
    fi
    
    if [ -z "$SERVER_SECRET" ]; then
        echo -e "${RED}Server secret is required (use --server-secret or SERVERDOCK_SERVER_SECRET env var)${NC}"
        exit 1
    fi
    
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=ServerDock Agent
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/serverdock-agent
Restart=always
RestartSec=5
Environment="SERVERDOCK_BACKEND_URL=$BACKEND_URL"
Environment="SERVERDOCK_BOOTSTRAP_TOKEN=$BOOTSTRAP_TOKEN"
Environment="SERVERDOCK_SERVER_ID=$SERVER_ID"
Environment="SERVERDOCK_SERVER_SECRET=$SERVER_SECRET"

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    echo -e "${GREEN}Systemd service created${NC}"
}

# Start service
start_service() {
    echo -e "${YELLOW}Starting ServerDock agent service...${NC}"
    systemctl enable "$SERVICE_NAME"
    systemctl start "$SERVICE_NAME"
    
    sleep 2
    
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo -e "${GREEN}ServerDock agent is running${NC}"
    else
        echo -e "${RED}Failed to start ServerDock agent${NC}"
        systemctl status "$SERVICE_NAME"
        exit 1
    fi
}

# Main installation
main() {
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}ServerDock Agent Installer${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    
    check_root
    detect_system
    
    download_agent
    create_service
    start_service
    
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Installation complete!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo "Service status: systemctl status $SERVICE_NAME"
    echo "View logs: journalctl -u $SERVICE_NAME -f"
    echo ""
}

main

