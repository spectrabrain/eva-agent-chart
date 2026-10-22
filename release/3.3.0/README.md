# 3.3.0 배포 values

`3.2.1`을 복사한 공통 values이며 AWS/ECR 배포의 chart/image는 `3.3.0-rc.2`를 사용합니다. 정식 또는 다음 RC 배포에서는 버전을 명시적으로 지정하세요.

- Agent 이미지: `211722900905.dkr.ecr.ap-northeast-2.amazonaws.com/spectrabrain/eva-agent:3.3.0-rc.2`
- Agent ECR 갱신 hook/CronJob: 새 ECR registry를 사용하며, Agent 모델 cache PVC와 S3 preload 설정은 제거했습니다. 기존 cluster의 PVC/PV는 배포 전에 별도 보존 상태를 확인하세요.
- vLLM: 기존 모델 cache와 preload를 유지하며 S3 source를 `s3://spectrabrain-eva-agent/vllm/hf`로 설정했습니다.
- Qdrant S3 snapshot sidecar: Docker Hub의 `amazon/aws-cli:2.33.8` 이미지를 사용합니다. ORAS 보조 이미지는 Harbor OCI snapshot 경로에서만 사용합니다. 파일은 `s3://spectrabrain-eva-agent/agent/qdrant/eva_manual_qwen3vl_collections/eva_manual_qwen3vl_test_20260824.snapshot`, 복원 collection은 기존 `eva_manual_qwen3vl`입니다.

두 설치 script는 `eva-agent` Helm repo alias를 CI가 게시하는 `https://raw.githubusercontent.com/spectrabrain/eva-agent-chart/chartmuseum`으로 갱신합니다.

vLLM values의 기본 이미지와 저장소 설정은 `release/3.2.1`을 유지합니다. Docker variants는
`lmcache/lmstack-router:v0.1.10`, `vllm/vllm-openai:v0.21.0`을 사용하며 k3s NFS 기본값은
`localhost:/share/eva-agent/vllm-cache`입니다. Harbor variants는 Harbor 이미지와
`{{ eva_agent_nfs_share_path }}/vllm-cache`를 사용합니다. 실제 e2e의
`/data/share/eva-agent/vllm-cache`는 `tmp_release`의 환경별 override로 유지합니다.

## AWS 인증 갱신 위치

저장소 루트의 `install_eva_agent.sh`는 기본으로 local AWS `default` profile을 읽어 namespace의 `aws-credentials` Secret을 갱신합니다. 다른 profile은 `--profile`로 지정할 수 있습니다. ECR 로그인 hook과 CronJob이 이 Secret을 사용해 `eva-agent-dockerconfig` pull Secret을 새 registry로 갱신합니다. GitHub CI OIDC publisher Role과 cluster runtime 인증은 별도입니다. 자격 증명 값은 로그에 출력하지 않습니다.

아래 배포 명령은 실제 cluster를 변경하므로 준비가 끝난 뒤 실행하세요. 먼저 gitignore 대상인 `.values-3.3.0`에 values를 복사하고, 그 안의 `eva-agent/values-secret.yaml` placeholder를 실제 환경에 맞게 설정합니다. 이 파일은 script가 마지막에 자동 반영하므로 별도 `-f` 파일에 둔 동일 키를 덮어씁니다. 자격 증명은 채팅이나 git에 공유하지 않습니다.

```sh
cp -a release/3.3.0 .values-3.3.0
```

```sh
./install_eva_agent.sh \
  --base-dir .values-3.3.0 \
  --chart-version 3.3.0-rc.2 \
  --image 3.3.0-rc.2 \
  --profile default \
  --region ap-northeast-2 \
  --context e2e-pro5000 \
  --check-digest 1 \
  -f .values-3.3.0/eva-agent/values-k3s.ecr.yaml
```

의존성 설치 script도 `--aws-credential default`로 동일 Secret을 갱신할 수 있으며 region과 선택적 session token을 함께 반영합니다. 이미 Agent script에서 갱신했다면 이 옵션을 생략합니다. 의존성 script는 현재 kube context를 사용하므로 실행 전에 확인하세요.

```sh
./install_eva_agent_dependencies.sh \
  --base-dir .values-3.3.0 \
  --release 3.3.0 \
  --components vllm \
  --vllm-chart-version 3.3.0-rc.2 \
  --aws-credential default \
  --vllm-values .values-3.3.0/eva-agent-vllm/values-k3s.PRO5000x3.docker.yaml
```

## Qdrant 적용 전 확인

기존 snapshot sidecar는 시작할 때 `priority=snapshot`으로 collection을 복원합니다. 기존 collection이 있어도 덮어쓸 수 있으므로, AWS 인증과 image 변경만을 위해 Qdrant를 재시작하기 전에 현재 데이터와 복원 의도를 확인해야 합니다. 이 values 준비 과정에서는 cluster 복원이나 PVC 삭제를 수행하지 않았습니다. Harbor values는 별도 Harbor 배포 경로용이며 ECR/S3 설정과 혼합하지 않습니다.
