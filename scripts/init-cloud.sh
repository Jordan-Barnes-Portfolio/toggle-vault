#!/bin/bash
set -e

# =============================================================================
# Toggle Vault Cloud Initialization Script
# Supports USSec, USNat, and other Azure Government clouds
#
# This script fetches CA certificates from the Azure wireserver (168.63.129.16)
# which is accessible from within Azure VMs even in airgapped environments.
#
# Based on Azure's init-airgap-environment.sh pattern
# =============================================================================

echo "=== Toggle Vault Cloud Initialization ==="

# Configuration from environment or defaults
CLOUD_TYPE="${AZURE_CLOUD:-AzureUSGovernment}"
REGION="${AZURE_REGION:-usgovvirginia}"
CONFIG_FILE="${CONFIG_FILE:-/config/config.yaml}"
CERT_OUTPUT_DIR="${CERT_OUTPUT_DIR:-/shared/certs}"
AZURE_CONFIG_DIR="${AZURE_CONFIG_DIR:-/shared/azure}"

# Azure wireserver endpoint (constant for all Azure VMs)
WIRESERVER_ENDPOINT="http://168.63.129.16"
WIRESERVER_CA_URL="${WIRESERVER_ENDPOINT}/machine?comp=acmspackage&type=cacertificates&ext=json"

# Cloud-specific endpoints
declare -A CLOUD_ENDPOINTS
declare -A CLOUD_SUFFIXES

# Azure Public
CLOUD_ENDPOINTS["AzureCloud"]="https://management.azure.com"
CLOUD_SUFFIXES["AzureCloud"]="windows.net"

# Azure US Government
CLOUD_ENDPOINTS["AzureUSGovernment"]="https://management.usgovcloudapi.net"
CLOUD_SUFFIXES["AzureUSGovernment"]="usgovcloudapi.net"

# Azure US Secret (USSec) - Air-gapped environment
# Regions: usseceast, ussecwest, ussecwestcentral
CLOUD_ENDPOINTS["AzureUSSecret"]="https://management.azure.microsoft.scloud"
CLOUD_SUFFIXES["AzureUSSecret"]="microsoft.scloud"

# Azure US Top Secret (USNat)
# Regions: usnateast, usnatwest
CLOUD_ENDPOINTS["AzureUSNat"]="https://management.azure.eaglex.ic.gov"
CLOUD_SUFFIXES["AzureUSNat"]="eaglex.ic.gov"

# =============================================================================
# Functions
# =============================================================================

log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

log_warn() {
    echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Parse cloud configuration from config.yaml if available
parse_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        log_info "Parsing configuration from $CONFIG_FILE"
        
        # Extract cloud settings if yq is available, otherwise use grep
        if command -v yq &> /dev/null; then
            CLOUD_TYPE=$(yq eval '.azure.cloud // "AzureUSGovernment"' "$CONFIG_FILE")
            REGION=$(yq eval '.azure.region // "usgovvirginia"' "$CONFIG_FILE")
        else
            # Fallback to grep/sed parsing
            local cloud_line=$(grep -E "^\s*cloud:" "$CONFIG_FILE" 2>/dev/null | head -1)
            local region_line=$(grep -E "^\s*region:" "$CONFIG_FILE" 2>/dev/null | head -1)
            
            if [[ -n "$cloud_line" ]]; then
                CLOUD_TYPE=$(echo "$cloud_line" | sed 's/.*cloud:\s*["]*\([^"]*\)["]*$/\1/' | tr -d '"' | xargs)
            fi
            if [[ -n "$region_line" ]]; then
                REGION=$(echo "$region_line" | sed 's/.*region:\s*["]*\([^"]*\)["]*$/\1/' | tr -d '"' | xargs)
            fi
        fi
        
        log_info "Cloud Type: $CLOUD_TYPE"
        log_info "Region: $REGION"
    else
        log_warn "Config file not found at $CONFIG_FILE, using environment variables"
    fi
}

# Download and install CA certificates from Azure wireserver
# This is the standard approach for airgapped Azure environments
install_ca_certificates_from_wireserver() {
    log_info "Fetching CA certificates from Azure wireserver..."
    log_info "Wireserver URL: $WIRESERVER_CA_URL"
    
    mkdir -p "$CERT_OUTPUT_DIR"
    
    # Fetch certificates from wireserver with retry logic
    # The wireserver is always available at 168.63.129.16 from within Azure VMs
    local certs_json
    certs_json=$(curl -v --connect-timeout 30 --retry 10 --retry-delay 5 "$WIRESERVER_CA_URL" 2>/dev/null)
    
    if [[ -z "$certs_json" ]]; then
        log_error "Failed to fetch certificates from wireserver"
        return 1
    fi
    
    log_info "Successfully fetched certificate data from wireserver"
    
    # Save raw response for debugging
    echo "$certs_json" > "$CERT_OUTPUT_DIR/wireserver-response.json"
    
    # Parse the JSON response and extract certificates
    # The response contains Name and CertBody fields
    local IFS_backup=$IFS
    IFS=$'\r\n'
    
    # Extract certificate names and bodies using grep with Perl regex
    local certNames=($(echo "$certs_json" | grep -oP '(?<=Name": ")[^"]*' || true))
    local certBodies=($(echo "$certs_json" | grep -oP '(?<=CertBody": ")[^"]*' || true))
    
    IFS=$IFS_backup
    
    if [[ ${#certBodies[@]} -eq 0 ]]; then
        log_warn "No certificates found in wireserver response, trying alternate parsing..."
        
        # Try jq if available
        if command -v jq &> /dev/null; then
            jq -r '.Certificates[]? | .CertBody // empty' "$CERT_OUTPUT_DIR/wireserver-response.json" 2>/dev/null | while read -r cert; do
                if [[ -n "$cert" ]]; then
                    # Convert escaped newlines and write as PEM
                    echo "$cert" | sed 's/\\r\\n/\n/g' | sed 's/\\//g'
                fi
            done > "$CERT_OUTPUT_DIR/azure-ca-bundle.pem"
        fi
    else
        log_info "Found ${#certBodies[@]} certificates"
        
        # Process each certificate
        for i in "${!certBodies[@]}"; do
            local certName="${certNames[$i]:-cert-$i}"
            local certBody="${certBodies[$i]}"
            
            # Clean up the certificate name (replace .cer with .crt, ensure .crt extension)
            local cleanName=$(echo "$certName" | sed 's/.cer/.crt/g' | sed 's/\.[^.]*$/.crt&/;t;s/$/.crt/')
            
            # Write certificate to file, converting Windows line endings
            echo "$certBody" | sed 's/\\r\\n/\n/g' | sed 's/\\//g' > "$CERT_OUTPUT_DIR/$cleanName"
            
            log_info "Extracted certificate: $cleanName"
        done
    fi
    
    # Combine all certificates into a single bundle
    if ls "$CERT_OUTPUT_DIR"/*.crt 1> /dev/null 2>&1; then
        cat "$CERT_OUTPUT_DIR"/*.crt > "$CERT_OUTPUT_DIR/ca-bundle.crt"
        log_info "Created combined CA bundle: $CERT_OUTPUT_DIR/ca-bundle.crt"
    elif ls "$CERT_OUTPUT_DIR"/*.pem 1> /dev/null 2>&1; then
        cat "$CERT_OUTPUT_DIR"/*.pem > "$CERT_OUTPUT_DIR/ca-bundle.crt"
        log_info "Created combined CA bundle from PEM files"
    else
        log_error "No certificate files were created"
        return 1
    fi
    
    # Copy to system CA directory for immediate use (if we have permission)
    if [[ -d "/usr/local/share/ca-certificates" ]]; then
        cp "$CERT_OUTPUT_DIR"/*.crt /usr/local/share/ca-certificates/ 2>/dev/null || true
        update-ca-certificates 2>/dev/null || log_warn "Could not update system CA certificates (may need root)"
    fi
    
    # Also copy to OpenSSL location if it exists
    if [[ -f "/etc/ssl/certs/ca-certificates.crt" ]]; then
        cat "$CERT_OUTPUT_DIR/ca-bundle.crt" >> /etc/ssl/certs/ca-certificates.crt 2>/dev/null || true
    fi
    if [[ -d "/usr/lib/ssl" ]]; then
        cp /etc/ssl/certs/ca-certificates.crt /usr/lib/ssl/cert.pem 2>/dev/null || true
    fi
    
    log_info "CA certificates installed to $CERT_OUTPUT_DIR"
    
    # Count certificates in bundle
    local cert_count=$(grep -c "BEGIN CERTIFICATE" "$CERT_OUTPUT_DIR/ca-bundle.crt" 2>/dev/null || echo "0")
    log_info "Total certificates in bundle: $cert_count"
}

# Generate cloud-specific configuration for the main application
generate_app_config() {
    log_info "Generating application cloud configuration"
    
    mkdir -p "$AZURE_CONFIG_DIR"
    
    local storage_suffix="${CLOUD_SUFFIXES[$CLOUD_TYPE]:-windows.net}"
    local management_endpoint="${CLOUD_ENDPOINTS[$CLOUD_TYPE]:-https://management.azure.com}"
    
    # Write cloud configuration that can be sourced by main container
    cat > "$AZURE_CONFIG_DIR/cloud-config.env" <<EOF
# Auto-generated cloud configuration
# Cloud: $CLOUD_TYPE
# Region: $REGION
# Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')

AZURE_CLOUD=$CLOUD_TYPE
AZURE_REGION=$REGION
AZURE_STORAGE_SUFFIX=$storage_suffix
AZURE_MANAGEMENT_ENDPOINT=$management_endpoint

# CA Certificate paths - set these in your application
REQUESTS_CA_BUNDLE=$CERT_OUTPUT_DIR/ca-bundle.crt
SSL_CERT_FILE=$CERT_OUTPUT_DIR/ca-bundle.crt
CURL_CA_BUNDLE=$CERT_OUTPUT_DIR/ca-bundle.crt
NODE_EXTRA_CA_CERTS=$CERT_OUTPUT_DIR/ca-bundle.crt
EOF

    # Also write as JSON for applications that prefer it
    cat > "$AZURE_CONFIG_DIR/cloud-config.json" <<EOF
{
    "cloud": "$CLOUD_TYPE",
    "region": "$REGION",
    "storageSuffix": "$storage_suffix",
    "managementEndpoint": "$management_endpoint",
    "caCertBundle": "$CERT_OUTPUT_DIR/ca-bundle.crt"
}
EOF

    # Write Azure CLI cloud registration script (to be run by main container if needed)
    cat > "$AZURE_CONFIG_DIR/register-cloud.sh" <<'AZURESCRIPT'
#!/bin/bash
# Register sovereign cloud with Azure CLI
# Source this script or run it to configure az cli

CLOUD_TYPE="${AZURE_CLOUD:-AzureUSGovernment}"

case $CLOUD_TYPE in
    "AzureCloud")
        az cloud set --name AzureCloud
        ;;
    "AzureUSGovernment")
        az cloud set --name AzureUSGovernment
        ;;
    "AzureUSSecret")
        if ! az cloud show --name AzureUSSecret 2>/dev/null; then
            az cloud register \
                --name AzureUSSecret \
                --endpoint-resource-manager "https://management.azure.microsoft.scloud" \
                --endpoint-active-directory "https://login.microsoftonline.microsoft.scloud" \
                --endpoint-active-directory-graph-resource-id "https://graph.microsoft.scloud" \
                --endpoint-active-directory-resource-id "https://management.azure.microsoft.scloud" \
                --suffix-storage-endpoint "core.microsoft.scloud" \
                --suffix-keyvault-dns ".vault.microsoft.scloud"
        fi
        az cloud set --name AzureUSSecret
        ;;
    "AzureUSNat")
        if ! az cloud show --name AzureUSNat 2>/dev/null; then
            az cloud register \
                --name AzureUSNat \
                --endpoint-resource-manager "https://management.azure.eaglex.ic.gov" \
                --endpoint-active-directory "https://login.microsoftonline.eaglex.ic.gov" \
                --endpoint-active-directory-graph-resource-id "https://graph.eaglex.ic.gov" \
                --endpoint-active-directory-resource-id "https://management.azure.eaglex.ic.gov" \
                --suffix-storage-endpoint "core.eaglex.ic.gov" \
                --suffix-keyvault-dns ".vault.eaglex.ic.gov"
        fi
        az cloud set --name AzureUSNat
        ;;
esac
AZURESCRIPT

    chmod +x "$AZURE_CONFIG_DIR/register-cloud.sh"

    log_info "Application configuration written to $AZURE_CONFIG_DIR"
}

# =============================================================================
# Main Execution
# =============================================================================

main() {
    log_info "Starting cloud initialization..."
    log_info "Cloud Type (env): ${AZURE_CLOUD:-not set}"
    log_info "Region (env): ${AZURE_REGION:-not set}"
    
    # Parse configuration
    parse_config
    
    # Install CA certificates from wireserver
    # This works in all Azure environments including airgapped
    install_ca_certificates_from_wireserver || log_warn "CA certificate installation had issues"
    
    # Generate application configuration
    generate_app_config
    
    # Mark initialization as complete
    touch "$AZURE_CONFIG_DIR/.initialized"
    
    log_info "=== Cloud initialization complete ==="
    log_info "Cloud: $CLOUD_TYPE"
    log_info "Region: $REGION"
    log_info "Certificates: $CERT_OUTPUT_DIR"
    log_info "Azure Config: $AZURE_CONFIG_DIR"
    
    exit 0
}

main "$@"
