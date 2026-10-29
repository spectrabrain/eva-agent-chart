#!/bin/bash

set -euo pipefail

kustom_path_root=./tmp
kustom_path="$(mkdir -p "${kustom_path_root}" && mktemp -d -p "${kustom_path_root}")"
cleanup() {
  cd - >/dev/null 2>&1 || true
  rm -rf "${kustom_path_root}"
}
trap cleanup EXIT

cd "${kustom_path}"

# post-renderer stdin to all.yaml
cat <&0 > all.yaml

# The Qdrant chart's serviceAccount.name is not propagated to the StatefulSet
# pod. Keep this post-renderer limited to that compatibility patch. Snapshot
# download and recovery are handled by the snapshot reconciler sidecar.
cat > patch1.yaml << 'EOF'
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: placeholder-name
spec:
  template:
    spec:
      serviceAccountName: sa-eva-agent
EOF

cat > patch2.yaml << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: placeholder-name
spec:
  serviceAccountName: sa-eva-agent
EOF

cat > kustomization.yaml << 'EOF'
resources:
  - all.yaml
patches:
  - path: patch1.yaml
    target:
      kind: StatefulSet
      name: "^eva-agent-qdrant.*$"
  - path: patch2.yaml
    target:
      kind: Pod
      name: ".*-test-db-interaction$"
EOF

kustomize build .
