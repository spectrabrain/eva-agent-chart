#!/usr/bin/env bash

# If sourced, re-exec in a child bash to avoid killing the current shell.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  bash "${BASH_SOURCE[0]}" "$@"
  return $?
fi

# Safety flags: fail fast, no unset vars, propagate pipe errors.
set -euo pipefail

# EVA Agent deploy: sync AWS creds -> Helm upgrade -> optional rollout restart.

usage() {
  cat <<'USAGE'
Usage:
  ./install_eva_agent.sh [options]

Options:
  --chart <chart>                   Helm chart reference (default: eva-agent/eva-agent)
  --chart-version <ver>             Helm chart version (default: 3.2.0)
  --image <tag>                     Image tag (defaults to image.tag in provided values files)
  --namespace <ns>                  Namespace (default: eva-agent)
  --context <ctx>                   Kube context (default: current context)
  --base-dir <dir>                  Base directory with eva-agent values (default: pwd)
  --ecr-host <host>                 ECR host (default: 339713051385.dkr.ecr.ap-northeast-2.amazonaws.com)
  --ecr-repo <repo>                 ECR repo name (default: mellerikat/release/eva-agent)
  --profile <aws-profile>           AWS profile (default: default)
  --check-digest <0|1>              Compare digest when tag is the same (default: 0)
  --force-conflicts <0|1>           Force Helm to replace drifted resources on upgrade (default: 0)
  --aws-credentials-secret <name>   AWS credentials secret name (default: aws-credentials)
  --sync-aws-credentials <0|1>      Create/update aws credentials secret (default: 1)
  -f, --values <file>               Extra values file (repeatable)
  -h, --help                        Show help

Expected layout under base-dir:
  ./eva-agent/values-secret.yaml (optional, auto-included when present)
  ./eva-agent/values-k3s.ecr.yaml (optional standalone provider values)
  ./eva-agent/values-aws.yaml (optional standalone provider values)
  ./eva-agent/values-ncp.yaml (optional standalone provider values)

Examples:
  ./install_eva_agent.sh -f eva-agent/values-k3s.ecr.yaml
  ./install_eva_agent.sh --chart eva-agent/eva-agent --chart-version 3.2.0 -f eva-agent/values-aws.yaml
USAGE
}

mask_secret() {
  local value="${1:-}"
  local len="${#value}"
  if [ "$len" -le 8 ]; then
    printf '****'
    return
  fi
  printf '%s****%s' "${value:0:4}" "${value: -4}"
}

# Defaults (override via env vars or CLI).
NS="${NS:-eva-agent}"
AWS_ECR_HOST="${AWS_ECR_HOST:-339713051385.dkr.ecr.ap-northeast-2.amazonaws.com}"
AWS_PROFILE="${AWS_PROFILE:-}"
ECR_REPO_NAME="${ECR_REPO_NAME:-mellerikat/release/eva-agent}"
CHART="${CHART:-eva-agent/eva-agent}"
CHART_VERSION="${CHART_VERSION:-3.2.0}"
IMAGE_TAG="${IMAGE_TAG:-}"
CHECK_DIGEST="${CHECK_DIGEST:-0}"
FORCE_CONFLICTS="${FORCE_CONFLICTS:-0}"
BASE_DIR="${BASE_DIR:-$(pwd)}"
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
AWS_CREDENTIALS_SECRET="${AWS_CREDENTIALS_SECRET:-aws-credentials}"
SYNC_AWS_CREDENTIALS="${SYNC_AWS_CREDENTIALS:-1}"
EXTRA_VALUES=()

HELM_VERSION_RAW="$(helm version --short 2>/dev/null || true)"
HELM_VERSION_RAW="${HELM_VERSION_RAW#v}"
HELM_MAJOR="${HELM_VERSION_RAW%%.*}"
if [ -z "$HELM_MAJOR" ]; then
  echo "[ERROR] Failed to detect Helm version." >&2
  exit 1
fi

# Parse CLI args (extra values are collected in an array).
while [ "${1:-}" != "" ]; do
  case "$1" in
    --chart) CHART="$2"; shift 2 ;;
    --chart-version) CHART_VERSION="$2"; shift 2 ;;
    --image) IMAGE_TAG="$2"; shift 2 ;;
    --namespace) NS="$2"; shift 2 ;;
    --context) KUBE_CONTEXT="$2"; shift 2 ;;
    --base-dir) BASE_DIR="$2"; shift 2 ;;
    --ecr-host) AWS_ECR_HOST="$2"; shift 2 ;;
    --ecr-repo) ECR_REPO_NAME="$2"; shift 2 ;;
    --profile) AWS_PROFILE="$2"; shift 2 ;;
    --check-digest) CHECK_DIGEST="$2"; shift 2 ;;
    --force-conflicts) FORCE_CONFLICTS="$2"; shift 2 ;;
    --aws-credentials-secret) AWS_CREDENTIALS_SECRET="$2"; shift 2 ;;
    --sync-aws-credentials) SYNC_AWS_CREDENTIALS="$2"; shift 2 ;;
    -f|--values) EXTRA_VALUES+=("$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[ERROR] Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

case "$FORCE_CONFLICTS" in
  0|1) ;;
  *)
    echo "[ERROR] Invalid value for --force-conflicts: ${FORCE_CONFLICTS}. Expected 0 or 1." >&2
    usage
    exit 1
    ;;
esac

echo "[INFO] Namespace: ${NS}"
echo "[INFO] ECR Host: ${AWS_ECR_HOST}"
echo "[INFO] Chart: ${CHART}"
echo "[INFO] Base Dir: ${BASE_DIR}"
echo "[INFO] Force Conflicts: ${FORCE_CONFLICTS}"

# If not provided, default to the "default" AWS profile.
if [ -z "$AWS_PROFILE" ]; then
  AWS_PROFILE="default"
fi
echo "[INFO] AWS Profile: ${AWS_PROFILE}"
echo "[INFO] AWS Credentials Secret: ${AWS_CREDENTIALS_SECRET}"

VALUES_DIR="${BASE_DIR}/eva-agent"

HELM_CONTEXT_ARGS=()
KUBECTL_CONTEXT_ARGS=()
if [ -n "$KUBE_CONTEXT" ]; then
  HELM_CONTEXT_ARGS=(--kube-context "$KUBE_CONTEXT")
  KUBECTL_CONTEXT_ARGS=(--context "$KUBE_CONTEXT")
  echo "[INFO] Kube Context: ${KUBE_CONTEXT}"
fi

# Resolve IMAGE_TAG from provided values files when not provided.
if [ -z "$IMAGE_TAG" ]; then
  for values_path in "${EXTRA_VALUES[@]}"; do
    if [ -f "$values_path" ]; then
      tag_from_values="$(awk '
        $1 == "image:" {in_image=1; next}
        in_image && $1 == "tag:" {gsub(/"/, "", $2); print $2; exit}
        in_image && $1 ~ /^[A-Za-z_]/ {in_image=0}
      ' "$values_path")"
      if [ -n "$tag_from_values" ]; then
        IMAGE_TAG="$tag_from_values"
      fi
    fi
  done
fi

if [ -n "$IMAGE_TAG" ]; then
  echo "[INFO] Image Tag: ${IMAGE_TAG}"
else
  echo "[INFO] IMAGE_TAG not set; Helm chart/default values will be used."
fi

# Resolve chart version from Helm metadata when not provided.
if [ -z "$CHART_VERSION" ]; then
  CHART_VERSION="$(helm show chart "$CHART" | awk -F': ' '/^version:/{print $2; exit}')"
fi

if [ -z "$CHART_VERSION" ]; then
  echo "Failed to resolve chart version for ${CHART}. Set CHART_VERSION manually." >&2
  exit 1
fi
echo "[INFO] Chart Version: ${CHART_VERSION}"

# Sync AWS credentials into the target cluster (used by initContainer + ECR refresh CronJob).
if [ "$SYNC_AWS_CREDENTIALS" = "1" ]; then
  echo "[INFO] Syncing AWS credentials to secret ${AWS_CREDENTIALS_SECRET}..."
  aws_access_key_id="$(aws configure get aws_access_key_id --profile "$AWS_PROFILE" || true)"
  aws_secret_access_key="$(aws configure get aws_secret_access_key --profile "$AWS_PROFILE" || true)"
  aws_session_token="$(aws configure get aws_session_token --profile "$AWS_PROFILE" || true)"
  if [ "$aws_session_token" = "None" ]; then
    aws_session_token=""
  fi

  if [ -z "$aws_access_key_id" ] || [ -z "$aws_secret_access_key" ]; then
    echo "[ERROR] Missing aws_access_key_id or aws_secret_access_key for profile '${AWS_PROFILE}'." >&2
    echo "[ERROR] Available profiles:" >&2
    aws configure list-profiles >&2 || true
    exit 1
  fi

  echo "[INFO] AWS_ACCESS_KEY_ID: $(mask_secret "$aws_access_key_id")"
  echo "[INFO] AWS_SECRET_ACCESS_KEY: $(mask_secret "$aws_secret_access_key")"
  if [ -n "$aws_session_token" ]; then
    echo "[INFO] AWS_SESSION_TOKEN: present"
  else
    echo "[INFO] AWS_SESSION_TOKEN: not set"
  fi

  secret_args=(
    --from-literal=AWS_ACCESS_KEY_ID="$aws_access_key_id"
    --from-literal=AWS_SECRET_ACCESS_KEY="$aws_secret_access_key"
  )
  if [ -n "$aws_session_token" ]; then
    secret_args+=(--from-literal=AWS_SESSION_TOKEN="$aws_session_token")
  fi

  kubectl "${KUBECTL_CONTEXT_ARGS[@]}" -n "$NS" create secret generic "$AWS_CREDENTIALS_SECRET" \
    "${secret_args[@]}" --dry-run=client -o yaml | \
    kubectl "${KUBECTL_CONTEXT_ARGS[@]}" -n "$NS" apply -f -
  echo "[INFO] AWS credentials secret applied."
fi

# Detect the currently deployed image tag to handle same-tag rollouts.
prev_image="$(kubectl "${KUBECTL_CONTEXT_ARGS[@]}" -n "$NS" get deploy eva-agent \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
prev_tag=""
if [ -n "$prev_image" ] && [ "${prev_image#*@}" = "$prev_image" ]; then
  prev_tag="${prev_image##*:}"
fi

extra_values_args=()
for values_path in "${EXTRA_VALUES[@]}"; do
  extra_values_args+=(-f "$values_path")
done
secret_values_args=()
secret_values_path="${VALUES_DIR}/values-secret.yaml"
if [ -f "$secret_values_path" ]; then
  secret_values_args=(-f "$secret_values_path")
else
  echo "[INFO] values file not found: ${secret_values_path} (skip)"
fi

helm_upgrade_args=()
if [ "$FORCE_CONFLICTS" = "1" ]; then
  if [ "$HELM_MAJOR" -ge 4 ]; then
    helm_upgrade_args+=(--force-conflicts)
  else
    helm_upgrade_args+=(--force)
  fi
fi

echo "[INFO] Running helm upgrade..."
helm upgrade --install eva-agent "$CHART" --version="$CHART_VERSION" -n "$NS" \
  "${HELM_CONTEXT_ARGS[@]}" \
  "${extra_values_args[@]}" \
  "${secret_values_args[@]}" \
  "${helm_upgrade_args[@]}" \
  ${IMAGE_TAG:+--set image.tag="$IMAGE_TAG"}

# If the tag is the same, compare digests and restart if needed.
if [ -n "$IMAGE_TAG" ] && [ -n "$prev_tag" ] && [ "$prev_tag" = "$IMAGE_TAG" ]; then
  if [ "$CHECK_DIGEST" = "1" ]; then
    desired_digest="$(aws ecr describe-images \
      --repository-name "$ECR_REPO_NAME" \
      --image-ids imageTag="$IMAGE_TAG" \
      --query 'imageDetails[0].imageDigest' \
      --output text 2>/dev/null || true)"
    if [ "$desired_digest" = "None" ]; then
      desired_digest=""
    fi

    current_image_id="$(kubectl "${KUBECTL_CONTEXT_ARGS[@]}" -n "$NS" get pod -l app.kubernetes.io/name=eva-agent \
      -o jsonpath='{.items[0].status.containerStatuses[0].imageID}' 2>/dev/null || true)"
    current_digest="${current_image_id##*@}"

    if [ -n "$desired_digest" ] && [ -n "$current_digest" ] && [ "$current_digest" != "$desired_digest" ]; then
      echo "[INFO] Digest mismatch -> rollout restart"
      kubectl "${KUBECTL_CONTEXT_ARGS[@]}" rollout restart deploy/eva-agent -n "$NS"
    else
      echo "[INFO] Digest matches -> skip rollout restart"
    fi
  else
    echo "[INFO] CHECK_DIGEST=0 -> restart on same tag"
    kubectl "${KUBECTL_CONTEXT_ARGS[@]}" rollout restart deploy/eva-agent -n "$NS"
  fi
else
  echo "[INFO] Image tag changed or missing -> Helm rollout is sufficient"
fi

# No temporary files to cleanup.
