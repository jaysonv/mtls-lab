#!/bin/bash
set -e

echo "===== Creating directory structure ====="
rm -rf mtls-lab
mkdir -p mtls-lab/{ca,server,client}
cd mtls-lab

########################################
# STEP 1 — CREATE ROOT CA CONFIG
########################################
cat > ca/openssl.cnf <<EOF
[ ca ]
default_ca = CA_default

[ CA_default ]
dir               = .
certificate       = \$dir/ca_cert.pem
private_key       = \$dir/ca_key.pem
new_certs_dir     = \$dir/certs
database          = \$dir/index.txt
serial            = \$dir/serial
default_md        = sha256
policy            = policy_loose
copy_extensions   = copy
default_days      = 825

[ policy_loose ]
commonName        = supplied

[ req ]
prompt            = no
distinguished_name = dn
x509_extensions   = v3_ca

[ dn ]
CN = Test Root CA

[ v3_ca ]
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always,issuer
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, keyCertSign, cRLSign

###############################################
# SERVER CERT EXTENSIONS
###############################################
[ server_good ]
basicConstraints = CA:false
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @san

[ server_wrong ]
basicConstraints = CA:false
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
subjectAltName = @san

[ server_noeku ]
basicConstraints = CA:false
keyUsage = critical, digitalSignature, keyEncipherment
subjectAltName = @san

###############################################
# CLIENT CERT EXTENSIONS
###############################################
[ client_good ]
basicConstraints = CA:false
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth

[ client_wrong ]
basicConstraints = CA:false
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth

[ client_noeku ]
basicConstraints = CA:false
keyUsage = critical, digitalSignature, keyEncipherment

[ san ]
DNS.1 = localhost
EOF

########################################
# STEP 2 — INIT CA DB
########################################
cd ca
mkdir -p certs newcerts
touch index.txt
echo 1000 > serial
echo "unique_subject = no" > index.txt.attr

########################################
# STEP 3 — GENERATE ROOT CA
########################################
openssl req -x509 -newkey rsa:4096 -nodes \
  -keyout ca_key.pem -out ca_cert.pem \
  -days 3650 -config openssl.cnf

cd ..

########################################
# STEP 4 — SERVER CERT CSRs
########################################
openssl req -new -newkey rsa:2048 -nodes \
  -keyout server/server_key.pem \
  -out server/server_csr.pem \
  -subj "/CN=localhost"

########################################
# STEP 5 — CLIENT CERT CSRs
########################################
openssl req -new -newkey rsa:2048 -nodes \
  -keyout client/client_key.pem \
  -out client/client_csr.pem \
  -subj "/CN=test-client"

########################################
# STEP 6 — SIGN SERVER CERTS
########################################
cd ca
openssl ca -config openssl.cnf -extensions server_good \
  -in ../server/server_csr.pem -out ../server/server_good.pem -batch

openssl ca -config openssl.cnf -extensions server_wrong \
  -in ../server/server_csr.pem -out ../server/server_wrong.pem -batch

openssl ca -config openssl.cnf -extensions server_noeku \
  -in ../server/server_csr.pem -out ../server/server_noeku.pem -batch

########################################
# STEP 7 — SIGN CLIENT CERTS
########################################
openssl ca -config openssl.cnf -extensions client_good \
  -in ../client/client_csr.pem -out ../client/client_good.pem -batch

openssl ca -config openssl.cnf -extensions client_wrong \
  -in ../client/client_csr.pem -out ../client/client_wrong.pem -batch

openssl ca -config openssl.cnf -extensions client_noeku \
  -in ../client/client_csr.pem -out ../client/client_noeku.pem -batch

cd ..

########################################
# STEP 8 — WRITE NGINX CONFIG
########################################
cat > nginx.conf <<EOF
server {
    listen 443 ssl;

    ssl_certificate /etc/nginx/certs/server_cert.pem;
    ssl_certificate_key /etc/nginx/certs/server_key.pem;

    ssl_client_certificate /etc/nginx/certs/ca_cert.pem;
    ssl_verify_client on;

    location / {
        return 200 "mTLS OK\n";
    }
}
EOF

########################################
# STEP 9 — GENERATE HELPER SCRIPTS
########################################
if [ ! -f start-nginx.sh ]; then
cat > start-nginx.sh <<'SCRIPT'
#!/bin/bash
SERVER_CERT="${1:-server/server_good.pem}"
echo "Starting NGINX with server cert: $SERVER_CERT"
docker rm -f mtls-nginx 2>/dev/null
docker run -d --name mtls-nginx \
  -p 8443:443 \
  -v "$(pwd)/nginx.conf:/etc/nginx/conf.d/default.conf:ro" \
  -v "$(pwd)/${SERVER_CERT}:/etc/nginx/certs/server_cert.pem:ro" \
  -v "$(pwd)/server/server_key.pem:/etc/nginx/certs/server_key.pem:ro" \
  -v "$(pwd)/ca/ca_cert.pem:/etc/nginx/certs/ca_cert.pem:ro" \
  nginx:alpine
SCRIPT
chmod +x start-nginx.sh
echo "  Created start-nginx.sh"
fi

if [ ! -f stop-nginx.sh ]; then
cat > stop-nginx.sh <<'SCRIPT'
#!/bin/bash
docker rm -f mtls-nginx 2>/dev/null
echo "NGINX stopped."
SCRIPT
chmod +x stop-nginx.sh
echo "  Created stop-nginx.sh"
fi

if [ ! -f run-tests.sh ]; then
cat > run-tests.sh <<'TESTSCRIPT'
#!/bin/bash
#
# run-tests.sh — Automated mTLS test matrix
# Runs all 9 combinations of server × client certificates against NGINX.
#
set -e

PORT=8443
HOST="localhost"
URL="https://${HOST}:${PORT}"

if ! curl -sk --max-time 3 "$URL" --cert client/client_good.pem --key client/client_key.pem >/dev/null 2>&1; then
    echo "ERROR: NGINX not reachable on $URL"
    echo "  Run: ./start-nginx.sh"
    exit 1
fi

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'; BOLD='\033[1m'

SERVER_CERTS=("server_good" "server_wrong" "server_noeku")
SERVER_EKUS=("serverAuth" "clientAuth" "no EKU")
CLIENT_CERTS=("client_good" "client_wrong" "client_noeku")
CLIENT_EKUS=("clientAuth" "serverAuth" "no EKU")

pass_count=0; fail_count=0

swap_server_cert() {
    local cert_name="$1"
    docker rm -f mtls-nginx 2>/dev/null
    docker run -d --name mtls-nginx \
        -p "${PORT}:443" \
        -v "$(pwd)/nginx.conf:/etc/nginx/conf.d/default.conf:ro" \
        -v "$(pwd)/server/${cert_name}.pem:/etc/nginx/certs/server_cert.pem:ro" \
        -v "$(pwd)/server/server_key.pem:/etc/nginx/certs/server_key.pem:ro" \
        -v "$(pwd)/ca/ca_cert.pem:/etc/nginx/certs/ca_cert.pem:ro" \
        nginx:alpine >/dev/null
    sleep 2
}

test_combo() {
    local client_cert="$1"
    local result
    result=$(curl -sk --max-time 5 "$URL" \
        --cert "client/${client_cert}.pem" \
        --key client/client_key.pem 2>&1)
    if echo "$result" | grep -q "mTLS OK"; then echo "PASS"; else echo "FAIL"; fi
}

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║               mTLS Test Matrix (curl -k / insecure)                ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════════╝${NC}"
echo ""
printf "  ${BOLD}%-30s %-30s %-10s${NC}\n" "SERVER CERT" "CLIENT CERT" "RESULT"
printf "  %-30s %-30s %-10s\n" "------------------------------" "------------------------------" "----------"

for si in 0 1 2; do
    server="${SERVER_CERTS[$si]}"; server_eku="${SERVER_EKUS[$si]}"
    swap_server_cert "$server"
    for ci in 0 1 2; do
        client="${CLIENT_CERTS[$ci]}"; client_eku="${CLIENT_EKUS[$ci]}"
        result=$(test_combo "$client")
        if [ "$result" = "PASS" ]; then
            color=$GREEN; symbol="✅ PASS"; ((pass_count++))
        else
            color=$RED; symbol="❌ FAIL"; ((fail_count++))
        fi
        printf "  %-30s %-30s ${color}%-10s${NC}\n" \
            "${server}.pem (${server_eku})" "${client}.pem (${client_eku})" "$symbol"
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
swap_server_cert "server_good"
echo "  (Restored server_good.pem as default server cert)"
echo "  To stop NGINX:  ./stop-nginx.sh  or  docker rm -f mtls-nginx"
echo ""
TESTSCRIPT
chmod +x run-tests.sh
echo "  Created run-tests.sh"
fi

########################################
# STEP 10 — PRINT TEST COMMANDS
########################################
echo ""
echo "===== DONE! Certificates generated ====="
echo ""
echo "SERVER CERTIFICATES:"
echo "  server_good.pem   (EKU: serverAuth)"
echo "  server_wrong.pem  (EKU: clientAuth — deliberately wrong)"
echo "  server_noeku.pem  (no EKU — unrestricted)"
echo ""
echo "CLIENT CERTIFICATES:"
echo "  client_good.pem   (EKU: clientAuth)"
echo "  client_wrong.pem  (EKU: serverAuth — deliberately wrong)"
echo "  client_noeku.pem  (no EKU — unrestricted)"
echo ""
echo "===== EKU VALIDATION RULES ====="
echo "  • EKU present + includes required purpose  → ACCEPTED"
echo "  • EKU present + MISSING required purpose   → REJECTED"
echo "  • EKU absent (no extension at all)         → ACCEPTED (unrestricted)"
echo "  • curl -k skips ALL server cert validation"
echo ""
echo "===== START NGINX ====="
echo ""
echo "  Option A — Using script:"
echo "    cd mtls-lab && ./start-nginx.sh"
echo "    ./start-nginx.sh server/server_wrong.pem   # with different cert"
echo ""
echo "  Option B — Manual docker command:"
echo "    cd mtls-lab"
echo "    docker run -d --name mtls-nginx -p 8443:443 \\"
echo "      -v \$(pwd)/nginx.conf:/etc/nginx/conf.d/default.conf:ro \\"
echo "      -v \$(pwd)/server/server_good.pem:/etc/nginx/certs/server_cert.pem:ro \\"
echo "      -v \$(pwd)/server/server_key.pem:/etc/nginx/certs/server_key.pem:ro \\"
echo "      -v \$(pwd)/ca/ca_cert.pem:/etc/nginx/certs/ca_cert.pem:ro \\"
echo "      nginx:alpine"
echo ""
echo "===== STOP NGINX ====="
echo "  ./stop-nginx.sh   or   docker rm -f mtls-nginx"
echo ""
echo "===== RUN ALL TESTS ====="
echo "  ./run-tests.sh   or   cd .. && ./run-tests.sh"
echo ""
echo "===== TEST COMMANDS ====="
echo ""
echo "GOOD mTLS (expect 200):"
echo '  curl -vk https://localhost:8443 --cert client/client_good.pem --key client/client_key.pem'
echo ""
echo "FAIL — client has wrong EKU (expect SSL handshake error):"
echo '  curl -vk https://localhost:8443 --cert client/client_wrong.pem --key client/client_key.pem'
echo ""
echo "FAIL — client has no EKU (expect SSL handshake error):"
echo '  curl -vk https://localhost:8443 --cert client/client_noeku.pem --key client/client_key.pem'
echo ""
echo "To test server wrong/no EKU, swap the server cert in docker-compose.yml:"
echo "  server_wrong.pem  → curl will reject the TLS connection"
echo "  server_noeku.pem  → curl will reject the TLS connection"
echo ""
