#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mongo-live.XXXXXX")
TLS_CONTAINER="mongo-live-tls-$$"
RS_CONTAINER="mongo-live-rs-$$"
TLS_VOLUME="mongo-live-tls-data-$$"
TLS_USER=mongo_live
TLS_PASSWORD=$(openssl rand -hex 24)

cleanup() {
    docker rm -f "$TLS_CONTAINER" "$RS_CONTAINER" >/dev/null 2>&1 || true
    docker volume rm "$TLS_VOLUME" >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT
trap 'exit 130' HUP INT TERM

for tool in docker openssl slangc; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "mongo live tests require $tool" >&2
        exit 1
    fi
done

docker image inspect mongo:8.2.12 >/dev/null 2>&1 || docker pull mongo:8.2.12

cat >"$TMP_DIR/server.cnf" <<'EOF'
[req]
distinguished_name = subject
prompt = no
req_extensions = server_ext

[subject]
CN = localhost

[server_ext]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @names

[names]
DNS.1 = localhost
IP.1 = 127.0.0.1
EOF

openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP_DIR/ca.key" \
    -out "$TMP_DIR/ca.pem" -days 2 -subj "/CN=slang-mongo-live-ca" \
    >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP_DIR/untrusted.key" \
    -out "$TMP_DIR/untrusted-ca.pem" -days 2 \
    -subj "/CN=slang-mongo-untrusted-ca" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -keyout "$TMP_DIR/server.key" \
    -out "$TMP_DIR/server.csr" -config "$TMP_DIR/server.cnf" \
    >/dev/null 2>&1
openssl x509 -req -in "$TMP_DIR/server.csr" -CA "$TMP_DIR/ca.pem" \
    -CAkey "$TMP_DIR/ca.key" -CAcreateserial -out "$TMP_DIR/server.crt" \
    -days 2 -extfile "$TMP_DIR/server.cnf" -extensions server_ext \
    >/dev/null 2>&1
cat "$TMP_DIR/server.key" "$TMP_DIR/server.crt" >"$TMP_DIR/server.pem"
chmod 600 "$TMP_DIR/server.pem"

docker volume create "$TLS_VOLUME" >/dev/null
docker run --detach --name "$TLS_CONTAINER" --publish 127.0.0.1::27017 \
    --volume "$TLS_VOLUME:/data/db" \
    mongo:8.2.12 mongod --bind_ip_all >/dev/null
TLS_PORT=$(docker port "$TLS_CONTAINER" 27017/tcp | sed 's/.*://')

attempt=0
until docker exec "$TLS_CONTAINER" mongosh --quiet \
    --eval 'db.adminCommand({ping:1}).ok' >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 60 ]; then
        docker logs "$TLS_CONTAINER" >&2
        echo "temporary MongoDB user-setup server did not start" >&2
        exit 1
    fi
    sleep 1
done

docker exec "$TLS_CONTAINER" mongosh --quiet admin --eval \
    "db.createUser({user:'$TLS_USER',pwd:'$TLS_PASSWORD',roles:[{role:'root',db:'admin'}]})" \
    >/dev/null
docker rm -f "$TLS_CONTAINER" >/dev/null
docker run --detach --name "$TLS_CONTAINER" \
    --publish "127.0.0.1:$TLS_PORT:27017" \
    --volume "$TLS_VOLUME:/data/db" \
    --volume "$TMP_DIR/server.pem:/run/mongo/server.pem:ro" \
    --volume "$TMP_DIR/ca.pem:/run/mongo/ca.pem:ro" \
    mongo:8.2.12 mongod --bind_ip_all --tlsMode requireTLS \
    --tlsCertificateKeyFile /run/mongo/server.pem \
    --tlsCAFile /run/mongo/ca.pem --tlsAllowConnectionsWithoutCertificates \
    --auth >/dev/null

attempt=0
until docker exec "$TLS_CONTAINER" mongosh --quiet \
    "mongodb://$TLS_USER:$TLS_PASSWORD@localhost:27017/admin?authSource=admin&tls=true&tlsCAFile=/run/mongo/ca.pem" \
    --eval 'db.adminCommand({ping:1}).ok' >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 60 ]; then
        docker logs "$TLS_CONTAINER" >&2
        echo "temporary MongoDB TLS/auth server did not start" >&2
        exit 1
    fi
    sleep 1
done

cd "$ROOT/tests/live"
slangc main.sl -o "$TMP_DIR/mongo-live"
TLS_COLLECTION="live_tls_$$"
TLS_URI="mongodb://$TLS_USER:$TLS_PASSWORD@localhost:$TLS_PORT/slang_mongo_live_test?authSource=admin&tls=true&tlsCAFile=$TMP_DIR/ca.pem"
"$TMP_DIR/mongo-live" --uri "$TLS_URI" --collection "$TLS_COLLECTION"
TLS_BAD_AUTH_URI="mongodb://$TLS_USER:wrong-password@localhost:$TLS_PORT/slang_mongo_live_test?authSource=admin&tls=true&tlsCAFile=$TMP_DIR/ca.pem"
"$TMP_DIR/mongo-live" --uri "$TLS_BAD_AUTH_URI" --expect-error SCRAM
TLS_BAD_CA_URI="mongodb://$TLS_USER:$TLS_PASSWORD@localhost:$TLS_PORT/slang_mongo_live_test?authSource=admin&tls=true&tlsCAFile=$TMP_DIR/untrusted-ca.pem"
"$TMP_DIR/mongo-live" --uri "$TLS_BAD_CA_URI" --expect-error TLS

docker run --detach --name "$RS_CONTAINER" --publish 127.0.0.1::27017 \
    mongo:8.2.12 mongod --bind_ip_all --replSet rs0 >/dev/null
RS_PORT=$(docker port "$RS_CONTAINER" 27017/tcp | sed 's/.*://')

attempt=0
until docker exec "$RS_CONTAINER" mongosh --quiet \
    --eval 'db.adminCommand({ping:1}).ok' >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 60 ]; then
        docker logs "$RS_CONTAINER" >&2
        echo "temporary replica-set server did not start" >&2
        exit 1
    fi
    sleep 1
done
docker exec "$RS_CONTAINER" mongosh --quiet --eval \
    'rs.initiate({_id:"rs0",members:[{_id:0,host:"localhost:27017"}]})' \
    >/dev/null

attempt=0
until [ "$(docker exec "$RS_CONTAINER" mongosh --quiet \
    --eval 'String(db.hello().isWritablePrimary)' 2>/dev/null || true)" = true ]; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 60 ]; then
        docker logs "$RS_CONTAINER" >&2
        echo "temporary MongoDB replica set did not elect a primary" >&2
        exit 1
    fi
    sleep 1
done

RS_COLLECTION="live_txn_$$"
"$TMP_DIR/mongo-live" --uri \
    "mongodb://127.0.0.1:$RS_PORT/slang_mongo_live_test" \
    --collection "$RS_COLLECTION" --transactions

echo "PASS MongoDB 8.2.12 TLS/auth rejection and replica-set integration suite"
