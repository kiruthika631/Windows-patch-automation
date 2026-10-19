#!/usr/bin/env bash
# Push main to https://github.com/kiruthika631/Windows-patch-automation
#
# One-time token setup (prefer nano over echo — avoids token in shell history):
#   nano ~/.github_token          # paste PAT only (one line), save
#   chmod 600 ~/.github_token
#
# Fine-grained PAT for this repo:
#   Repository access: Windows-patch-automation
#   Permissions: Contents Read/Write, Workflows Read/Write, Metadata Read
#
# Classic PAT: scopes "repo" and "workflow"
#
# Usage:
#   cd /home/tpx-admin/.cursor-server/Windows-Patch-Automation-Framework
#   ./scripts/push_to_kiruthika631_github.sh
#
set -euo pipefail

TOKEN_FILE="${HOME}/.github_token"
USER="${GITHUB_USER:-kiruthika631}"
REPO_NAME="${REPO_NAME:-Windows-patch-automation}"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${BASE_DIR}"

if [[ ! -f "${TOKEN_FILE}" ]]; then
  echo "ERROR: Missing ${TOKEN_FILE}"
  echo "  nano ${TOKEN_FILE}   # paste token, save"
  echo "  chmod 600 ${TOKEN_FILE}"
  exit 1
fi

TOKEN="$(tr -d '[:space:]' < "${TOKEN_FILE}")"
export GIT_TERMINAL_PROMPT=0

api() {
  curl -sS -H "Authorization: Bearer ${TOKEN}" -H "Accept: application/vnd.github+json" "$@"
}

LOGIN="$(api https://api.github.com/user | python3 -c "import sys,json; print(json.load(sys.stdin).get('login',''))")"
if [[ "${LOGIN}" != "${USER}" ]]; then
  echo "ERROR: token does not authenticate as ${USER} (got: '${LOGIN:-bad credentials}')."
  exit 1
fi

repo_exists() {
  local code
  code="$(api -o /dev/null -w '%{http_code}' "https://api.github.com/repos/${USER}/${REPO_NAME}")"
  [[ "$code" == "200" ]]
}

if ! repo_exists; then
  api -X POST "https://api.github.com/user/repos" \
    -d "{\"name\":\"${REPO_NAME}\",\"private\":false,\"description\":\"Windows Patch Automation updates — VMware Guest Operations orchestration, docs, and GitHub Actions\"}" \
    > /tmp/create-kiruthika631-patch-repo.json
  if ! repo_exists; then
    echo "ERROR: could not create ${USER}/${REPO_NAME}. Create empty repo on GitHub or fix token permissions."
    python3 -c "import json; d=json.load(open('/tmp/create-kiruthika631-patch-repo.json')); print(d.get('message',''))" 2>/dev/null || true
    exit 1
  fi
  echo "Created https://github.com/${USER}/${REPO_NAME}"
fi

git remote remove kiruthika631 2>/dev/null || true
git remote add kiruthika631 "https://github.com/${USER}/${REPO_NAME}.git"

CRED_HELPER='!f() { echo username=x-access-token; echo "password=$(cat '"${TOKEN_FILE}"')"; }; f'
if ! git -c "credential.helper=${CRED_HELPER}" push -u kiruthika631 main 2> /tmp/push-kiruthika631-patch.err; then
  if grep -q 'workflow' /tmp/push-kiruthika631-patch.err 2>/dev/null; then
    echo "ERROR: token needs Workflows: Read and write (fine-grained) or workflow scope (classic)."
  elif grep -q 'Permission.*denied\|403' /tmp/push-kiruthika631-patch.err 2>/dev/null; then
    echo "ERROR: token needs Contents: Read and write on ${REPO_NAME}."
  elif grep -q 'Repository not found' /tmp/push-kiruthika631-patch.err 2>/dev/null; then
    echo "ERROR: repository not found — check repo name and token repository access."
  fi
  cat /tmp/push-kiruthika631-patch.err >&2
  exit 1
fi

echo "SUCCESS: https://github.com/${USER}/${REPO_NAME}"
