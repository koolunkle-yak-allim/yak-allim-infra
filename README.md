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

## Nginx 무중단(블루-그린) 배포 구조

1. Jenkins 파이프라인이 Spring Boot 신규 컨테이너(`yak-allim-backend-blue` 또는 `yak-allim-backend-green`)를 생성 및 헬스 체크 진행.
2. 헬스 체크 성공 시 `./nginx/conf.d/service-url.inc` 및 배포 공유 디렉터리의 `service-url.inc`에 대상 서비스 URL 업데이트:
   `set $service_url http://yak-allim-backend-blue:8081;`
3. Jenkins가 `docker exec yak-allim-nginx nginx -s reload` 명령을 실행하여 다운타임 없이 Nginx 라우팅 전환 완료.

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
