#!/usr/bin/env bash
# Deploy from your laptop exactly the way GitHub Actions does:
# copy the code to a new release folder on EC2 and run deploy.sh there.
#
# Usage: deployment/push-release.sh [--simulate-failure]
# Env:   EC2_HOST (default 3.80.226.178), EC2_USER (default ubuntu),
#        SSH_KEY  (default ~/Downloads/CloudDeploy-Deploy-Key.pem)
set -euo pipefail
cd "$(dirname "$0")/.."

EC2_HOST="${EC2_HOST:-3.80.226.178}"
EC2_USER="${EC2_USER:-ubuntu}"
SSH_KEY="${SSH_KEY:-$HOME/Downloads/CloudDeploy-Deploy-Key.pem}"
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo manual)"
RELEASE="/opt/shopflow/releases/${SHA}-$(date +%s)"
SSH="ssh -i $SSH_KEY -o IdentitiesOnly=yes"

echo "Uploading release $RELEASE to $EC2_USER@$EC2_HOST"
rsync -az --delete -e "$SSH" \
  --exclude .git --exclude .venv --exclude __pycache__ --exclude .pytest_cache --exclude '*.pem' \
  ./ "$EC2_USER@$EC2_HOST:$RELEASE/"

$SSH "$EC2_USER@$EC2_HOST" \
  "APP_VERSION='$(cat VERSION)' BUILD_SHA='$SHA' bash '$RELEASE/deployment/deploy.sh' $*"
