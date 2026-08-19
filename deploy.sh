#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<EOF
Usage:
  $0 <service> <action> <subdomain> <env file path>

Actions:
  up
  down
  config

Examples:
  $0 module-ttt up rc5 /home/ubuntu/ttt/env/rc5.env
  $0 chat-app up chat /home/ubuntu/ttt/env/chat.env
EOF
    exit 1
}

[[ $# -eq 4 ]] || usage

SERVICE="$1"
ACTION="$2"
SUBDOMAIN="$3"
ENV_FILE="$4"

[[ -f "$ENV_FILE" ]] || {
    echo "Environment file not found: $ENV_FILE"
    exit 1
}

case "$ACTION" in
    up|down|config) ;;
    *) usage ;;
esac

case "$SERVICE" in
    module-ttt)
        COMPOSE_FILE="/home/ubuntu/ttt/infra-tdb-platform/docker/module-ttt.yaml"
        HOST_VAR="TTT_BACKEND_HOST"
        DOMAIN="talkingdb.io"
        ;;
    chat-app)
        COMPOSE_FILE="/home/ubuntu/flowbot-framework/docker-compose.yml"
        HOST_VAR="CHAT_HOST"
        DOMAIN="talkingdb.io"
        ;;
    *)
        echo "Unknown service: $SERVICE"
        exit 1
        ;;
esac

HOSTNAME="${SUBDOMAIN}.${DOMAIN}"

sudo env \
    COMPOSE_PROJECT_NAME="$SUBDOMAIN" \
    "$HOST_VAR=$HOSTNAME" \
    docker compose \
        --env-file "$ENV_FILE" \
        -f "$COMPOSE_FILE" \
        "$ACTION" \
        $([[ "$ACTION" == "up" ]] && echo "--build -d")