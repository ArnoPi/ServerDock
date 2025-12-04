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
    
    # Convert WebSocket URL to HTTP URL for binary download
    # ws://localhost:3001 -> http://localhost:3001
    # wss://api.serverdock.com -> https://api.serverdock.com
    HTTP_URL=$(echo "$BACKEND_URL" | sed 's|^wss\?://|http://|' | sed 's|/agent/connect$||')
    BINARY_URL="${HTTP_URL}/api/agent/download/${OS}/${ARCH}"
    
    mkdir -p "$INSTALL_DIR"
    
    # Try to download from backend
    HTTP_CODE=$(curl -s -o "$INSTALL_DIR/serverdock-agent" -w "%{http_code}" -L "$BINARY_URL" 2>/dev/null)
    BINARY_SIZE=$(stat -f%z "$INSTALL_DIR/serverdock-agent" 2>/dev/null || stat -c%s "$INSTALL_DIR/serverdock-agent" 2>/dev/null || echo "0")
    
    # Check if download was successful (HTTP 200 and binary size > 1KB)
    if [ "$HTTP_CODE" = "200" ] && [ "$BINARY_SIZE" -gt 1024 ]; then
        chmod +x "$INSTALL_DIR/serverdock-agent"
        echo -e "${GREEN}Agent binary downloaded (${BINARY_SIZE} bytes)${NC}"
        return 0
    else
        # Remove invalid download
        rm -f "$INSTALL_DIR/serverdock-agent"
        if [ "$HTTP_CODE" != "200" ]; then
            echo -e "${YELLOW}Download failed (HTTP $HTTP_CODE), will try to build locally...${NC}"
        else
            echo -e "${YELLOW}Downloaded file too small (${BINARY_SIZE} bytes), will try to build locally...${NC}"
        fi
    fi
    
    # If download fails, try to build locally
    echo -e "${YELLOW}Download failed, attempting to build agent locally...${NC}"
    
    # Check if Go is installed
    if ! command -v go &> /dev/null; then
        echo -e "${RED}Go is not installed. Cannot build agent binary.${NC}"
        echo -e "${YELLOW}Please install Go (https://golang.org/dl/) or ensure the backend has the binary available.${NC}"
        exit 1
    fi
    
    # Try to find agent source in common locations
    AGENT_DIR=""
    
    # Try current directory
    if [ -f "./cmd/serverdock-agent/main.go" ]; then
        AGENT_DIR="$(pwd)"
    # Try script directory (works when script is executed directly)
    elif [ -f "$(dirname "$0")/cmd/serverdock-agent/main.go" ]; then
        AGENT_DIR="$(cd "$(dirname "$0")" && pwd)"
    # Try common installation locations
    elif [ -f "/opt/serverdock-source/agent/cmd/serverdock-agent/main.go" ]; then
        AGENT_DIR="/opt/serverdock-source/agent"
    elif [ -f "/usr/local/src/serverdock/agent/cmd/serverdock-agent/main.go" ]; then
        AGENT_DIR="/usr/local/src/serverdock/agent"
    elif [ -f "/tmp/serverdock-agent/cmd/serverdock-agent/main.go" ]; then
        AGENT_DIR="/tmp/serverdock-agent"
    # Try to download source from GitHub as last resort
    else
        echo -e "${YELLOW}Agent source not found locally, attempting to download from GitHub...${NC}"
        TEMP_DIR=$(mktemp -d)
        if git clone --depth 1 https://github.com/ArnoPi/ServerDock.git "$TEMP_DIR" 2>/dev/null; then
            if [ -f "$TEMP_DIR/agent/cmd/serverdock-agent/main.go" ]; then
                AGENT_DIR="$TEMP_DIR/agent"
                echo -e "${GREEN}Source code downloaded from GitHub${NC}"
            else
                rm -rf "$TEMP_DIR"
            fi
        else
            rm -rf "$TEMP_DIR"
        fi
    fi
    
    if [ -z "$AGENT_DIR" ] || [ ! -f "$AGENT_DIR/cmd/serverdock-agent/main.go" ]; then
        echo -e "${RED}Agent source code not found${NC}"
        echo -e "${YELLOW}Please either:${NC}"
        echo -e "  1. Build the agent binary manually:"
        echo -e "     cd agent && go build -o /opt/serverdock/serverdock-agent ./cmd/serverdock-agent"
        echo -e "  2. Ensure the backend has the binary available at: ${BINARY_URL}"
        echo -e "  3. Clone the repository and run installer from agent directory:"
        echo -e "     git clone https://github.com/ArnoPi/ServerDock.git"
        echo -e "     cd ServerDock/agent && bash install.sh --token ... --server-id ..."
        exit 1
    fi
    
    # Build the agent
    echo -e "${YELLOW}Building agent binary from source...${NC}"
    cd "$AGENT_DIR" || exit 1
    
    # Download dependencies
    if [ -f "go.mod" ]; then
        echo -e "${YELLOW}Downloading Go dependencies...${NC}"
        go mod download || {
            echo -e "${RED}Failed to download Go dependencies${NC}"
            exit 1
        }
    fi
    
    # Build with optimizations
    echo -e "${YELLOW}Compiling agent binary...${NC}"
    if GOOS="$OS" GOARCH="$ARCH" go build -ldflags="-s -w" -o "$INSTALL_DIR/serverdock-agent" ./cmd/serverdock-agent; then
        chmod +x "$INSTALL_DIR/serverdock-agent"
        
        # Verify binary was created and is executable
        if [ -f "$INSTALL_DIR/serverdock-agent" ] && [ -x "$INSTALL_DIR/serverdock-agent" ]; then
            BINARY_SIZE=$(stat -f%z "$INSTALL_DIR/serverdock-agent" 2>/dev/null || stat -c%s "$INSTALL_DIR/serverdock-agent" 2>/dev/null || echo "0")
            echo -e "${GREEN}Agent binary built successfully (${BINARY_SIZE} bytes)${NC}"
        else
            echo -e "${RED}Binary was created but is not executable${NC}"
            exit 1
        fi
    else
        echo -e "${RED}Failed to build agent binary${NC}"
        echo -e "${YELLOW}Make sure Go is installed: https://golang.org/dl/${NC}"
        exit 1
    fi
    
    # Cleanup temporary directory if we cloned from GitHub
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ] && [ "$AGENT_DIR" = "$TEMP_DIR/agent" ]; then
        echo -e "${YELLOW}Cleaning up temporary files...${NC}"
        rm -rf "$TEMP_DIR"
    fi
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

