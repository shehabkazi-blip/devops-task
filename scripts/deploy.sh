#!/usr/bin/env bash
# Runs ON the EC2 instance (invoked by CI through SSM). Pulls IMAGE_TAG from ECR, restarts the
# stack, smoke-tests /health, and rolls back to the previously deployed tag on failure.
# Usage: scripts/deploy.sh <image-tag>
set -euo pipefail

TAG="${1:?usage: deploy.sh <image-tag>}"
APP_DIR="/opt/app"
cd "$APP_DIR"
# shellcheck source=/dev/null
source "$APP_DIR/instance.env"   # ECR_REPO, AWS_REGION, APP_ENV, LOG_GROUP, GRAFANA_PARAM

COMPOSE=(docker compose -f docker-compose.yml -f docker-compose.monitoring.yml -f docker-compose.aws.yml)
CURRENT_FILE="$APP_DIR/.current_tag"
PREVIOUS_TAG=""
[[ -f "$CURRENT_FILE" ]] && PREVIOUS_TAG=$(<"$CURRENT_FILE")

write_env() { # write_env TAG  (rewritten each time; the secret never touches git)
  local pw
  pw=$(aws ssm get-parameter --region "$AWS_REGION" --name "$GRAFANA_PARAM" \
        --with-decryption --query Parameter.Value --output text)
  umask 077
  cat > "$APP_DIR/.env" <<ENV
ECR_REPO=$ECR_REPO
IMAGE_TAG=$1
AWS_REGION=$AWS_REGION
APP_ENV=$APP_ENV
LOG_GROUP=$LOG_GROUP
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=$pw
ENABLE_FAULT_INJECTION=${ENABLE_FAULT_INJECTION:-false}
ENV
}

smoke_test() {
  local i
  for i in $(seq 1 30); do
    if curl -fsS -m 3 http://127.0.0.1:8080/health >/dev/null 2>&1; then
      echo "smoke test passed (attempt $i)"; return 0
    fi
    sleep 2
  done
  echo "smoke test FAILED after 60s" >&2
  return 1
}

# Called inside `if`, where bash ignores `set -e`, so the steps are chained explicitly.
rollout() { # rollout TAG
  write_env "$1" \
    && "${COMPOSE[@]}" pull app \
    && "${COMPOSE[@]}" up -d --remove-orphans
}

echo "Deploying tag '$TAG' (previous: '${PREVIOUS_TAG:-none}')"
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "${ECR_REPO%%/*}"

if rollout "$TAG" && smoke_test; then
  echo "$TAG" > "$CURRENT_FILE"
  docker image prune -f >/dev/null
  echo "Deploy of $TAG succeeded"
  exit 0
fi

echo "Deploy of $TAG failed" >&2
"${COMPOSE[@]}" logs --tail 30 app >&2 || true
if [[ -n "$PREVIOUS_TAG" ]]; then
  echo "Rolling back to $PREVIOUS_TAG" >&2
  if rollout "$PREVIOUS_TAG" && smoke_test; then
    echo "Rollback to $PREVIOUS_TAG succeeded" >&2
  else
    echo "ROLLBACK ALSO FAILED: manual intervention needed" >&2
  fi
else
  echo "No previous tag recorded: nothing to roll back to" >&2
fi
exit 1
