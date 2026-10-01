#!/bin/sh
# ---------------------------------------------------------------------------
# SSO Overlay — smoke-test-image.sh
# ---------------------------------------------------------------------------
# Boots a freshly built image the way the cluster runs it (login enabled,
# OAuth2/OIDC against Authentik, no license key) and asserts the overlay and
# the SSO login path actually work at runtime:
#
#   1. the app starts and /api/v1/info/status answers
#   2. PremiumFeatureUnlock ran and the license resolved to ENTERPRISE
#   3. the OIDC client registration was built from the issuer's discovery doc
#   4. the login page offers the SSO provider
#   5. /oauth2/authorization/<provider> redirects to the IdP's authorize URL
#   6. an admin API is refused without a session (login is enforced)
#   7. the LibreOffice sandbox launcher from the base image is present
#
# Only the public discovery document of the issuer is fetched; the client id
# and secret are dummies, so nothing is ever authenticated.
#
# Usage: smoke-test-image.sh <image>
#   SMOKE_ISSUER    OIDC issuer (default: the production Authentik app)
#   SMOKE_PROVIDER  registration id (default: authentik)
#   SMOKE_TIMEOUT   seconds to wait for startup (default: 420)
# Needs only a docker CLI; HTTP checks run with curl inside the container.
# ---------------------------------------------------------------------------
set -eu

IMAGE="${1:?usage: smoke-test-image.sh <image>}"
ISSUER="${SMOKE_ISSUER:-https://auth.kawalink.com/application/o/stirling-pdf/}"
PROVIDER="${SMOKE_PROVIDER:-authentik}"
TIMEOUT="${SMOKE_TIMEOUT:-420}"
NAME="sso-smoke-$$"
FAIL=0

ok()   { echo "  ok    $*"; }
bad()  { echo "  FAIL  $*"; FAIL=1; }
in_c() { docker exec "$NAME" sh -c "$1"; }

cleanup() {
  echo "------------------------------------------"
  echo "SSO smoke: container log (last 200 lines)"
  echo "------------------------------------------"
  docker logs --tail 200 "$NAME" 2>&1 || true
  docker stop -t 20 "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=========================================="
echo "SSO smoke: starting ${IMAGE}"
echo "  issuer=${ISSUER} provider=${PROVIDER}"
echo "=========================================="
docker run -d --rm --name "$NAME" \
  -e SECURITY_ENABLELOGIN=true \
  -e SECURITY_LOGINMETHOD=oauth2 \
  -e SECURITY_OAUTH2_ENABLED=true \
  -e SECURITY_OAUTH2_PROVIDER="$PROVIDER" \
  -e SECURITY_OAUTH2_ISSUER="$ISSUER" \
  -e SECURITY_OAUTH2_CLIENTID=sso-smoke-test \
  -e SECURITY_OAUTH2_CLIENTSECRET=sso-smoke-test \
  -e SECURITY_OAUTH2_SCOPES="openid, profile, email" \
  -e SECURITY_OAUTH2_USEASUSERNAME=email \
  -e SECURITY_OAUTH2_AUTOCREATEUSER=true \
  -e SECURITY_INITIALLOGIN_USERNAME=smokeadmin \
  -e SECURITY_INITIALLOGIN_PASSWORD=smoke-test-password-1 \
  -e SYSTEM_DEFAULTLOCALE=en-US \
  "$IMAGE" >/dev/null

i=0
until in_c 'curl -fs --max-time 5 http://localhost:8080/api/v1/info/status' >/dev/null 2>&1; do
  if [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" != "true" ]; then
    echo "SSO smoke: container exited during startup"
    exit 1
  fi
  i=$((i + 5))
  if [ "$i" -ge "$TIMEOUT" ]; then
    echo "SSO smoke: app not up after ${TIMEOUT}s"
    exit 1
  fi
  sleep 5
done
echo "SSO smoke: app up after ~${i}s"

LOGS="$(docker logs "$NAME" 2>&1)"
has() { printf '%s\n' "$LOGS" | grep -qF -- "$1"; }

has "Premium/Enterprise features unlocked" \
  && ok "PremiumFeatureUnlock ran" || bad "PremiumFeatureUnlock did not run"
has "granting Enterprise" \
  && ok "license resolved to ENTERPRISE without a key" || bad "license was not granted as ENTERPRISE"
has "Initialised OIDC OAuth2 provider: registrationId='${PROVIDER}'" \
  && ok "OIDC registration '${PROVIDER}' built from issuer discovery" || bad "OIDC registration '${PROVIDER}' missing"
if has "APPLICATION FAILED TO START"; then bad "Spring reported APPLICATION FAILED TO START"; fi
if has "sandbox launcher is not in this image"; then
  bad "LibreOffice sandbox launcher missing (base image too old?)"
else
  ok "LibreOffice sandbox launcher present"
fi

LOGIN="$(in_c 'curl -s --max-time 10 http://localhost:8080/api/v1/proprietary/ui-data/login' || true)"
case "$LOGIN" in
  *"/oauth2/authorization/${PROVIDER}"*) ok "login page offers /oauth2/authorization/${PROVIDER}" ;;
  *) bad "login data lacks the ${PROVIDER} provider: $(printf '%s' "$LOGIN" | head -c 400)" ;;
esac
case "$LOGIN" in
  *'"enableLogin":true'*) ok "login is enabled" ;;
  *) bad "login data does not report enableLogin=true" ;;
esac

REDIR="$(in_c "curl -s -o /dev/null --max-time 10 -w '%{http_code} %{redirect_url}' http://localhost:8080/oauth2/authorization/${PROVIDER}" || true)"
AUTHZ_PREFIX="$(printf '%s' "$ISSUER" | sed -E 's#^(https?://[^/]+)/.*#\1#')"
case "$REDIR" in
  "302 ${AUTHZ_PREFIX}"*client_id=sso-smoke-test*) ok "SSO redirect -> ${REDIR#302 }" ;;
  *) bad "SSO redirect unexpected: ${REDIR}" ;;
esac

CODE="$(in_c "curl -s -o /dev/null --max-time 10 -w '%{http_code}' http://localhost:8080/api/v1/admin/settings" || true)"
case "$CODE" in
  401|403) ok "admin API refused without a session (${CODE})" ;;
  *) bad "admin API answered ${CODE} without a session" ;;
esac

echo "=========================================="
if [ "$FAIL" -ne 0 ]; then
  echo "SSO smoke: FAILED"
  exit 1
fi
echo "SSO smoke: all checks passed"
