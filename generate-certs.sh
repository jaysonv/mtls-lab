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
# STEP 9 — WRITE START/STOP SCRIPTS
########################################
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

cat > stop-nginx.sh <<'SCRIPT'
#!/bin/bash
docker rm -f mtls-nginx 2>/dev/null
echo "NGINX stopped."
SCRIPT
chmod +x stop-nginx.sh

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
echo "  cd mtls-lab && ./start-nginx.sh"
echo ""
echo "  Or with a specific server cert:"
echo "  ./start-nginx.sh server/server_wrong.pem"
echo ""
echo "===== STOP NGINX ====="
echo "  ./stop-nginx.sh"
echo ""
echo "===== RUN ALL TESTS ====="
echo "  cd .. && ./run-tests.sh"
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
