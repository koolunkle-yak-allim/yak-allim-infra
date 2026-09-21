# Yak-Allim-Infra

> **복약 안내서 OCR 분석 기반 복약 관리 솔루션**

**Yak-Allim-Infra**는 Yak-Allim 서비스를 위한 공용 인프라(Nginx, Jenkins, n8n) 관리 저장소입니다.

---

## 서비스 구성

* **Nginx (Reverse Proxy)**: `http://localhost`
  * Dynamic Container DNS Resolution 및 블루-그린 무중단 스위칭 지원 (`service-url.inc`)
* **Jenkins (CI/CD Controller)**: `http://localhost:9090`
  * Dynamic Docker Agent 방식을 활용하여 백엔드(Spring Boot) 및 클라이언트(Android APK) 파이프라인 제어
* **n8n (Workflow Automation)**: `http://localhost:5678`
  * OCR 및 자동화 워크플로우 엔진

### 포트

| 서비스 | 포트 | 바인딩 | 공개 여부 |
| --- | --- | --- | --- |
| Nginx | 80 | `0.0.0.0:80` | 공개 (유일한 정식 진입점) |
| n8n | 5678 | `127.0.0.1:5678` | 로컬 전용 |
| Jenkins | 9090 | `127.0.0.1:9090` | 로컬 전용 |
| Spring Boot (blue) | 8082 → 컨테이너 8081 | `0.0.0.0:8082` | `yak-allim-server`의 `scripts/deploy.sh`가 블루-그린 전환 시 직접 관리 (이 저장소가 아닌 서버 저장소 범위) |
| Spring Boot (green) | 8083 → 컨테이너 8081 | `0.0.0.0:8083` | 위와 동일 |

### 서비스 구성도

```text
                         ┌─────────────┐
   외부/LAN ────:80────► │    Nginx    │
                         └──────┬──────┘
                                │ $service_url (블루-그린 동적 전환, service-url.inc)
                     ┌──────────┴──────────┐
                     ▼                     ▼
          yak-allim-backend-blue   yak-allim-backend-green
             (Spring Boot, :8082)      (Spring Boot, :8083)
                     │                     │
                     └──────────┬──────────┘
                                ▼
                      yak-allim-n8n (:5678, 로컬 전용)
                                │
                      yak-allim-jenkins (:9090, 로컬 전용)
```

> **보안 주의**: 이 구성은 로컬 개발·개인 포트폴리오 시연용입니다. TLS가 설정되어 있지 않고(443 비활성), Jenkins 컨테이너가 `root` 권한으로 `docker.sock`에 접근합니다(사실상 호스트 전체 제어 권한). 그대로 실제 운영 환경에 노출하지 말고, 최소한 TLS 적용과 Jenkins 권한 축소(예: `docker-socket-proxy`로 필요한 API만 개방)를 먼저 적용하세요.

## Nginx 무중단(블루-그린) 배포 구조

1. Jenkins 파이프라인이 Spring Boot 신규 컨테이너(`yak-allim-backend-blue` 또는 `yak-allim-backend-green`)를 생성 및 헬스 체크 진행.
2. 헬스 체크 성공 시 `./nginx/conf.d/service-url.inc` 및 배포 공유 디렉터리의 `service-url.inc`에 대상 서비스 URL 업데이트:
   `set $service_url http://yak-allim-backend-blue:8081;`
3. Jenkins가 `docker exec yak-allim-nginx nginx -s reload` 명령을 실행하여 다운타임 없이 Nginx 라우팅 전환 완료.

> `nginx/conf.d/service-url.inc`는 배포마다 덮어써지는 런타임 상태 파일이라 git에서 추적하지 않습니다(`.gitignore` 참고). `scripts/init-volumes.sh`가 최초 실행 시 `nginx/conf.d/service-url.inc.example`과 동일한 내용으로 생성합니다.

## 구동 방법

### 1. 환경 변수 설정

```bash
cp .env.example .env
```

### 2. 초기 네트워크 및 볼륨 설정

```bash
chmod +x scripts/init-volumes.sh
./scripts/init-volumes.sh
```

### 3. 인프라 서비스 실행

```bash
docker compose up -d
```

### 4. 인프라 상태 확인

```bash
docker compose ps
```

## 롤백 방법

배포가 잘못됐다면 `yak-allim-server` 저장소의 롤백 스크립트로 이전 빌드 이미지로 되돌립니다(재빌드 없이 블루-그린 전환만 다시 수행).

```bash
# yak-allim-server 저장소 루트에서
./scripts/rollback.sh <되돌릴 빌드 번호>
# 예: 42번 빌드가 문제였다면
./scripts/rollback.sh 42
```

`<빌드 번호>`는 `deploy.sh`가 이미지 정리 시 보존한(기본 최근 5개) 태그여야 합니다. 남아있는 태그는 `docker images yak-allim-backend`로 확인할 수 있습니다.

## 저장소 간 배포 흐름

`yak-allim-server`(애플리케이션 코드·CI)와 `yak-allim-infra`(이 저장소, 인프라)는 서로 다른 저장소지만 배포 시점에 아래처럼 이어집니다.

```text
[yak-allim-server 저장소]                          [이 저장소가 기동하는 호스트]

GitHub Actions (ubuntu-latest, 깃허브 호스티드 러너)
   │ push to main
   ▼
./gradlew build (테스트)
   │ 성공 시
   ▼
curl -X POST "$JENKINS_WEBHOOK_URL?token=..."  ────►  Jenkins (127.0.0.1:9090)
                                                           │ 웹훅 수신, 파이프라인 시작
                                                           ▼
                                                     Jenkinsfile: Build → Deploy
                                                           │ scripts/deploy.sh 실행
                                                           ▼
                                                     블루-그린 컨테이너 전환 + Nginx reload
```

> **GitHub 호스티드 러너는 `127.0.0.1`에만 열려 있는 로컬 Jenkins에 직접 접근할 수 없습니다.** 그래서 GitHub Actions 시크릿 `JENKINS_WEBHOOK_URL`에는 `http://localhost:9090/...`가 아니라, ngrok·Cloudflare Tunnel 같은 도구로 Jenkins를 외부에 터널링한 **공개 URL**을 넣어야 합니다. 임시 터널 URL은 재기동할 때마다 바뀔 수 있으므로, 가능하면 고정 도메인을 주는 터널(예: Cloudflare Tunnel의 named tunnel)을 쓰는 편이 안전합니다.
