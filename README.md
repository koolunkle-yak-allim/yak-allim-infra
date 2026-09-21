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

## n8n 워크플로우

`n8n/workflows/ocr.json`은 처방전 이미지 OCR → 약품 정보 구조화 → 서버 콜백까지 이어지는 n8n 워크플로우를 export한 것입니다(`ocr.type=n8n` 모드에서 사용). 자격 증명 값과 개인 리소스 ID는 제거되어 있으니, import 후 아래 항목을 직접 채워야 합니다.

### Import 방법

1. n8n 관리 화면(`http://localhost:5678`) 접속 후 **Workflows → Import from File**로 `n8n/workflows/ocr.json` 업로드.
2. 아래 자격 증명을 n8n의 Credentials 메뉴에서 새로 만들고 각 노드에 연결합니다.

   | 노드 | 필요한 자격 증명 | 비고 |
   | --- | --- | --- |
   | `Webhook` | Header Auth | 서버 → n8n 요청의 인바운드 인증. 값은 서버가 보내는 `X-N8N-WEBHOOK-SECRET` 헤더와 맞춰야 합니다 |
   | `Upstage OCR` | Bearer Auth | [Upstage Document AI](https://upstage.ai) API 키 |
   | `Google Gemini Chat Model` | Google Gemini(PaLM) API | Gemini API 키 |
   | `Append row in sheet` (비활성) | Google Sheets OAuth2 | 현재 비활성화 상태라 필수는 아닙니다. 사용하려면 본인 스프레드시트로 `documentId`/`sheetName`을 다시 지정해야 합니다 |

3. `Spring Boot` 노드(서버 콜백)의 `X-N8N-Secret` 헤더 값을 실제 비밀값으로 교체하고, 서버 쪽 `OCR_N8N_WEBHOOK_SECRET` 환경 변수와 동일한 값으로 맞춥니다. **`REPLACE_WITH_...`로 표시된 값이나 추측 가능한 문자열을 그대로 쓰지 마세요.**
4. `Webhook` 노드를 Production 모드로 활성화하면 `http://<n8n-host>:5678/webhook/ocr`로 요청을 받습니다. 이 URL을 서버의 `ocr.n8n.webhook-url`에 설정하세요.

### 워크플로우 개요

1. `Webhook` — 서버가 처방전 이미지를 멀티파트로 전송
2. `Upstage OCR` — 이미지에서 텍스트와 좌표를 추출
3. `Code in JavaScript` — OCR 응답을 LLM 입력 형식으로 가공, 쿼리스트링의 `jobId` 추출
4. `Basic LLM Chain`(Google Gemini) — 약품명·복용량·복용 횟수·기간·좌표를 구조화된 JSON으로 추출
5. `Spring Boot` — 결과를 서버 콜백(`POST /api/v1/ocr/n8n/callback/{jobId}`)으로 전송

`On form submission`/`Edit Fields`/`Split Out`/`Append row in sheet` 노드는 초기 개발 단계에서 쓰던 흐름(수동 폼 업로드 + Google Sheets 기록)의 흔적으로, 현재는 비활성화되어 있습니다.

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
