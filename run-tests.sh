#!/bin/bash
#
# run-tests.sh — Automated mTLS test matrix
#
# Runs all 9 combinations of server × client certificates against NGINX
# and prints a results table showing which pass and which fail.
#
# Usage:
#   ./generate-certs.sh          # generate certs first
#   cd mtls-lab && docker run -d --name mtls-nginx -p 8443:443 \   # start NGINX
#     -v $(pwd)/nginx.conf:/etc/nginx/conf.d/default.conf:ro \
#     -v $(pwd)/server/server_good.pem:/etc/nginx/certs/server_cert.pem:ro \
#     -v $(pwd)/server/server_key.pem:/etc/nginx/certs/server_key.pem:ro \
#     -v $(pwd)/ca/ca_cert.pem:/etc/nginx/certs/ca_cert.pem:ro \
#     nginx:alpine
#   cd .. && ./run-tests.sh               # run tests
#
set -e

MTLS_DIR="mtls-lab"
PORT=8443
HOST="localhost"
URL="https://${HOST}:${PORT}"

# Verify mtls-lab exists
if [ ! -d "$MTLS_DIR" ]; then
    echo "ERROR: $MTLS_DIR directory not found. Run ./generate-certs.sh first."
    exit 1
fi

# Check NGINX is reachable
if ! curl -sk --max-time 3 "$URL" --cert "$MTLS_DIR/client/client_good.pem" --key "$MTLS_DIR/client/client_key.pem" >/dev/null 2>&1; then
    echo "ERROR: NGINX not reachable on $URL"
    echo "  Run: cd $MTLS_DIR && docker run -d --name mtls-nginx -p 8443:443 \\"
    echo "    -v \$(pwd)/nginx.conf:/etc/nginx/conf.d/default.conf:ro \\"
    echo "    -v \$(pwd)/server/server_good.pem:/etc/nginx/certs/server_cert.pem:ro \\"
    echo "    -v \$(pwd)/server/server_key.pem:/etc/nginx/certs/server_key.pem:ro \\"
    echo "    -v \$(pwd)/ca/ca_cert.pem:/etc/nginx/certs/ca_cert.pem:ro \\"
    echo "    nginx:alpine"
    exit 1
fi

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'
BOLD='\033[1m'

SERVER_CERTS=("server_good" "server_wrong" "server_noeku")
SERVER_EKUS=("serverAuth" "clientAuth" "no EKU")
CLIENT_CERTS=("client_good" "client_wrong" "client_noeku")
CLIENT_EKUS=("clientAuth" "serverAuth" "no EKU")

pass_count=0
fail_count=0

# Function: swap server cert and restart NGINX
swap_server_cert() {
    local cert_name="$1"
    docker rm -f mtls-nginx 2>/dev/null
    docker run -d --name mtls-nginx \
        -p "${PORT}:443" \
        -v "$(cd "$MTLS_DIR" && pwd)/nginx.conf:/etc/nginx/conf.d/default.conf:ro" \
        -v "$(cd "$MTLS_DIR" && pwd)/server/${cert_name}.pem:/etc/nginx/certs/server_cert.pem:ro" \
        -v "$(cd "$MTLS_DIR" && pwd)/server/server_key.pem:/etc/nginx/certs/server_key.pem:ro" \
        -v "$(cd "$MTLS_DIR" && pwd)/ca/ca_cert.pem:/etc/nginx/certs/ca_cert.pem:ro" \
        nginx:alpine >/dev/null
    sleep 2  # wait for NGINX to start
}

# Function: test a single combination
test_combo() {
    local client_cert="$1"
    local result
    result=$(curl -sk --max-time 5 "$URL" \
        --cert "$MTLS_DIR/client/${client_cert}.pem" \
        --key "$MTLS_DIR/client/client_key.pem" 2>&1)
    if echo "$result" | grep -q "mTLS OK"; then
        echo "PASS"
    else
        echo "FAIL"
    fi
}

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║               mTLS Test Matrix (curl -k / insecure)                ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Print header
printf "  ${BOLD}%-30s %-30s %-10s${NC}\n" "SERVER CERT" "CLIENT CERT" "RESULT"
printf "  %-30s %-30s %-10s\n" "------------------------------" "------------------------------" "----------"

for si in 0 1 2; do
    server="${SERVER_CERTS[$si]}"
    server_eku="${SERVER_EKUS[$si]}"

    # Swap server cert and restart NGINX
    swap_server_cert "$server"

    for ci in 0 1 2; do
        client="${CLIENT_CERTS[$ci]}"
        client_eku="${CLIENT_EKUS[$ci]}"

        result=$(test_combo "$client")

        if [ "$result" = "PASS" ]; then
            color=$GREEN
            symbol="✅ PASS"
            ((pass_count++))
        else
            color=$RED
            symbol="❌ FAIL"
            ((fail_count++))
        fi

        printf "  %-30s %-30s ${color}%-10s${NC}\n" \
            "${server}.pem (${server_eku})" \
            "${client}.pem (${client_eku})" \
            "$symbol"
    done
    echo ""
done

echo -e "${BOLD}══════════════════════════════════════════════════════════════════════${NC}"
echo -e "  ${GREEN}Passed: ${pass_count}${NC}    ${RED}Failed: ${fail_count}${NC}    Total: $((pass_count + fail_count))"
echo ""

echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║                          EKU Validation Rules                       ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${YELLOW}Rule 1:${NC} EKU present + includes required purpose  → ${GREEN}ACCEPTED${NC}"
echo -e "  ${YELLOW}Rule 2:${NC} EKU present + MISSING required purpose   → ${RED}REJECTED${NC}"
echo -e "  ${YELLOW}Rule 3:${NC} No EKU extension at all                  → ${GREEN}ACCEPTED (unrestricted)${NC}"
echo -e "  ${YELLOW}Rule 4:${NC} curl -k skips ALL server cert validation"
echo ""

# Restore server_good as default and clean up
swap_server_cert "server_good"
echo "  (Restored server_good.pem as default server cert)"
echo ""
echo "  To stop NGINX:  docker rm -f mtls-nginx"
echo ""
