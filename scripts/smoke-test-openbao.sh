#!/usr/bin/env bash
set -ex
cd -- "$(dirname -- "$0")" || exit 1
source ./smoke-test-helper.sh

# Configuration
OPENBAO_CONTAINER="smoke-openbao"
OPENBAO_PORT=8200
OPENBAO_ROOT_TOKEN="smoke-root-token"
OPENBAO_ADDR="http://127.0.0.1:${OPENBAO_PORT}"
STACK_NAME="smoke-openbao"
SECRET_NAME="smoke_secret"
SECRET_PATH="database/mysql"
SECRET_FIELD="password"
SECRET_VALUE="openbao-smoke-pass-v1"
SECRET_VALUE_ROTATED="openbao-smoke-pass-v2"
COMPOSE_FILE="/tmp/smoke-openbao-compose.yml"

# Cleanup trap
cleanup() {
    echo -e "${RED}Running OpenBao smoke test cleanup...${DEF}"
    remove_stack "${STACK_NAME}"
    docker secret rm "${SECRET_NAME}" 2>/dev/null || true
    docker stop "${OPENBAO_CONTAINER}" 2>/dev/null || true
    docker rm   "${OPENBAO_CONTAINER}" 2>/dev/null || true
    remove_plugin
    rm -f "${COMPOSE_FILE}"
}
trap cleanup EXIT

# Create openbao container
info "Starting OpenBao dev container..."
docker run -d \
    --name "${OPENBAO_CONTAINER}" \
    --network host \
    -e "BAO_DEV_ROOT_TOKEN_ID=${OPENBAO_ROOT_TOKEN}" \
    -e "BAO_DEV_LISTEN_ADDRESS=0.0.0.0:${OPENBAO_PORT}" \
    quay.io/openbao/openbao:latest server -dev

# Wait for OpenBao to be ready
info "Waiting for OpenBao to be ready..."
elapsed=0
until docker exec "${OPENBAO_CONTAINER}" \
        bao status -address="${OPENBAO_ADDR}" &>/dev/null; do
    sleep 2
    elapsed=$((elapsed + 2))
    [ "${elapsed}" -lt 30 ] || die "OpenBao did not become ready within 30s."
done
success "OpenBao is ready."

# Setup policy
info "STEP 2: Policy defined (will be applied in step 3)."

# Apply policy on openbao
info "Applying policy to OpenBao..."
docker exec "${OPENBAO_CONTAINER}" \
    bao policy write -address="${OPENBAO_ADDR}" smoke-policy - << 'EOF'
path "secret/data/database/mysql" {
  capabilities = ["create", "update", "read", "list"]
}
path "secret/metadata/database/mysql" {
  capabilities = ["list"]
}
EOF
success "Policy applied."

# Add passwords (write test secret)
info "Writing test secret to OpenBao..."
docker exec "${OPENBAO_CONTAINER}" \
    bao kv put \
    -address="${OPENBAO_ADDR}" \
    "secret/${SECRET_PATH}" \
    "${SECRET_FIELD}=${SECRET_VALUE}"
success "Secret written: secret/${SECRET_PATH} ${SECRET_FIELD}=${SECRET_VALUE}"

# Create swarm stack definition
info "Creating swarm stack compose file..."
cat > "${COMPOSE_FILE}" << EOF
version: '3.8'

services:
  app:
    image: busybox:latest
    command: >
      sh -c "
        while true; do
          echo 'Current secret:' && cat /run/secrets/${SECRET_NAME}
          sleep 5
        done
      "
    secrets:
      - ${SECRET_NAME}
    deploy:
      replicas: 1
      restart_policy:
        condition: any
    networks:
      - smoke-network

secrets:
  ${SECRET_NAME}:
    driver: ${PLUGIN_NAME}
    labels:
      openbao_path: "${SECRET_PATH}"
      openbao_field: "${SECRET_FIELD}"

networks:
  smoke-network:
    driver: overlay
EOF
success "Stack compose file created."

# Get the tmp auth token from openbao
info "Getting auth token from OpenBao..."
OPENBAO_TOKEN=$(docker exec "${OPENBAO_CONTAINER}" \
    bao token create \
        -address="${OPENBAO_ADDR}" \
        -policy="smoke-policy" \
        -field=token)
success "Got auth token: ${OPENBAO_TOKEN}"

# Put the auth token in the plugin
info "Building plugin and setting OpenBao auth token..."
build_plugin

echo -e "${RED}Set plugin configuration${DEF}"
docker plugin set "${PLUGIN_NAME}" \
    SECRETS_PROVIDER="openbao" \
    OPENBAO_ADDR="${OPENBAO_ADDR}" \
    OPENBAO_AUTH_METHOD="token" \
    OPENBAO_TOKEN="${OPENBAO_TOKEN}" \
    OPENBAO_MOUNT_PATH="secret" \
    ENABLE_ROTATION="true" \
    ROTATION_INTERVAL="10s" \
    ENABLE_MONITORING="false"
success "Plugin configured with OpenBao token."

# Run (enable) the plugin
info "Enabling plugin..."
enable_plugin

# Run docker stack deploy
info "Deploying swarm stack..."
deploy_stack "${COMPOSE_FILE}" "${STACK_NAME}" 60


# Log docker service output
info "Logging service output..."
sleep 10
log_stack "${STACK_NAME}" "app"

# Compare password == logged secret
info "Verifying secret value matches expected password..."
verify_secret "${STACK_NAME}" "app" "${SECRET_NAME}" "${SECRET_VALUE}" 60

# Rotate the password and verify
info "Rotating secret in OpenBao..."
docker exec "${OPENBAO_CONTAINER}" \
    bao kv put \
    -address="${OPENBAO_ADDR}" \
    "secret/${SECRET_PATH}" \
    "${SECRET_FIELD}=${SECRET_VALUE_ROTATED}"
success "Secret rotated to: ${SECRET_VALUE_ROTATED}"

info "Waiting for plugin rotation interval (15s)..."
sleep 15

info "Logging service output after rotation..."
log_stack "${STACK_NAME}" "app"

info "Verifying rotated secret value..."
verify_secret "${STACK_NAME}" "app" "${SECRET_NAME}" "${SECRET_VALUE_ROTATED}" 60

success "============================================"
success " OpenBao smoke test PASSED (incl. rotation)"
success "============================================"