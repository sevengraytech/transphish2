#!/bin/bash
# verify-keycloak-integration.sh - Verify Keycloak integration with Evilginx

set -euo pipefail

EVILGINX_CONTAINER="evilginx"
KEYCLOAK_CONTAINER="keycloak"
KEYCLOAK_DB_CONTAINER="keycloak-db"

echo "=== Keycloak Integration Verification ==="
echo ""

# Check containers are running
echo "1. Checking container status..."
docker-compose ps

echo ""
echo "2. Checking Keycloak health..."
if docker exec $KEYCLOAK_CONTAINER curl -s -f http://localhost:8080/health/ready >/dev/null 2>&1; then
    echo "✓ Keycloak health check passed"
else
    echo "✗ Keycloak health check failed"
    docker logs $KEYCLOAK_CONTAINER --tail 20
fi

echo ""
echo "3. Checking Keycloak realm import..."
if docker exec $KEYCLOAK_CONTAINER curl -s http://localhost:8080/realms/evilginx/.well-known/openid-configuration >/dev/null 2>&1; then
    echo "✓ Evilginx realm accessible"
else
    echo "✗ Evilginx realm not accessible"
fi

echo ""
echo "4. Checking Evilginx status..."
if docker exec evilginx /usr/local/bin/evilginx -c /config -p /config/phishlets phishlets 2>/dev/null; then
    echo "✓ Evilginx phishlets loaded"
else
    echo "✗ Evilginx phishlets not loaded"
fi

echo ""
echo "5. Checking Keycloak integration in Evilginx..."
if docker exec evilginx curl -s http://keycloak:8080/health/ready >/dev/null 2>&1; then
    echo "✓ Evilginx can reach Keycloak"
else
    echo "✗ Evilginx cannot reach Keycloak"
fi

echo ""
echo "6. Checking Evilginx config for OAuth2..."
if docker exec evilginx cat /config/config.json 2>/dev/null | python3 -c "
import sys, json
try:
    config = json.load(sys.stdin)
    phishlets = config.get('phishlets', {})
    for name, data in phishlets.items():
        oauth2 = data.get('oauth2', {})
        if oauth2:
            print(f'✓ {name}: OAuth2 configured - client_id={oauth2.get(\"client_id\", \"N/A\")}')
        else:
            print(f'✗ {name}: No OAuth2 config')
except Exception as e:
    print(f'Error: {e}')
    sys.exit(1)
"; then
    echo "✓ OAuth2 configs found in Evilginx"
else
    echo "✗ OAuth2 configs missing or invalid"
fi

echo ""
echo "7. Checking Keycloak clients..."
ADMIN_TOKEN=$(docker exec keycloak curl -s -X POST http://localhost:8080/realms/master/protocol/openid-connect/token \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=password" \
    -d "client_id=admin-cli" \
    -d "username=admin" \
    -d "password=admin123" 2>/dev/null | python3 -c "import sys, json; print(json.load(sys.stdin).get('access_token', ''))")

if [ -n "$ADMIN_TOKEN" ]; then
    echo "✓ Keycloak admin token obtained"
    
    # List clients in evilginx realm
    docker exec keycloak curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
        http://localhost:8080/admin/realms/evilginx/clients 2>/dev/null | python3 -c "
import sys, json
try:
    clients = json.load(sys.stdin)
    for c in clients:
        print(f'  - {c[\"clientId\"]}: enabled={c.get(\"enabled\", False)}')
except:
    pass
"
else
    echo "✗ Could not get Keycloak admin token"
fi

echo ""
echo "8. Checking Evilginx phishlet OAuth2 config..."
docker exec evilginx cat /config/config.json 2>/dev/null | python3 -c "
import sys, json
try:
    config = json.load(sys.stdin)
    phishlets = config.get('phishlets', {})
    for name, data in phishlets.items():
        oauth2 = data.get('oauth2', {})
        if oauth2:
            print(f'{name}:')
            print(f'  client_id: {oauth2.get(\"client_id\", \"N/A\")}')
            print(f'  redirect_uri: {oauth2.get(\"redirect_uri\", \"N/A\")}')
            print(f'  auth_endpoint: {oauth2.get(\"authorization_endpoint\", \"N/A\")}')
            print(f'  token_endpoint: {oauth2.get(\"token_endpoint\", \"N/A\")}')
            print(f'  userinfo_endpoint: {oauth2.get(\"userinfo_endpoint\", \"N/A\")}')
            print(f'  jwks_uri: {oauth2.get(\"jwks_uri\", \"N/A\")}')
            print(f'  scope: {oauth2.get(\"scope\", \"N/A\")}')
            print(f'  has_token: {\"yes\" if oauth2.get(\"access_token\") else \"no\"}')
        else:
            print(f'{name}: NO OAUTH2 CONFIG')
except Exception as e:
    print(f'Error: {e}')
"

echo ""
echo "=== Verification Complete ==="