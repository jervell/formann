#!/bin/bash

# Generic Secret Retrieval Utility
# Retrieves secrets from OS-specific credential storage

set -e  # Exit on error

# Detect operating system
detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        echo "linux"
    else
        echo "unsupported"
    fi
}

# Get keyctl key name with backward compatibility for claude-code-api
get_keyctl_key_name() {
    local service="$1"
    local account="$2"

    # For keyctl, use original hardcoded name for backward compatibility with existing installations
    if [ "$service" = "claude-code-api" ] && [ "$account" = "anthropic" ]; then
        echo "claude_code_api_key"  # Maintain backward compatibility
    else
        # For other services, use sanitized name (replace hyphens with underscores)
        echo "${service//-/_}_${account}"
    fi
}

# Parse command line arguments
SERVICE=""
ACCOUNT=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --service)
            SERVICE="$2"
            shift 2
            ;;
        --account)
            ACCOUNT="$2"
            shift 2
            ;;
        *)
            echo "Error: Unknown parameter: $1" >&2
            echo "Usage: $0 --service NAME --account NAME" >&2
            exit 1
            ;;
    esac
done

# Validate required parameters
if [ -z "$SERVICE" ] || [ -z "$ACCOUNT" ]; then
    echo "Error: Missing required parameters" >&2
    echo "Usage: $0 --service NAME --account NAME" >&2
    exit 1
fi

# Detect OS
OS=$(detect_os)

if [ "$OS" = "unsupported" ]; then
    echo "Error: Unsupported operating system: $OSTYPE" >&2
    exit 1
fi

# Retrieve secret based on OS
if [ "$OS" = "macos" ]; then
    SECRET=$(security find-generic-password -s "$SERVICE" -a "$ACCOUNT" -w 2>/dev/null) || {
        echo "Error: Secret not found in Keychain" >&2
        echo "Service: $SERVICE, Account: $ACCOUNT" >&2
        exit 1
    }
elif [ "$OS" = "linux" ]; then
    if command -v secret-tool &> /dev/null; then
        SECRET=$(secret-tool lookup service "$SERVICE" account "$ACCOUNT" 2>/dev/null) || {
            echo "Error: Secret not found in secret storage" >&2
            echo "Service: $SERVICE, Account: $ACCOUNT" >&2
            exit 1
        }
    elif command -v keyctl &> /dev/null; then
        KEY_NAME=$(get_keyctl_key_name "$SERVICE" "$ACCOUNT")
        SECRET=$(keyctl pipe $(keyctl search @s user "$KEY_NAME" 2>/dev/null) 2>/dev/null) || {
            echo "Error: Secret not found in kernel keyring" >&2
            echo "Key name: $KEY_NAME" >&2
            exit 1
        }
    else
        echo "Error: No supported secret storage found on Linux" >&2
        echo "Please install libsecret-tools or keyutils" >&2
        exit 1
    fi
fi

# Output the secret to stdout
echo "$SECRET"
