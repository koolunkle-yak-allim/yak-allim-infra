# n8n OCR 워크플로우 연동 가이드

`workflows/ocr.json`이 서버(`yak-allim-server`)와 주고받는 요청·콜백 설정과 실패 처리 방법을 정리합니다.
요청/응답 형식 자체는 서버 저장소의
[`docs/api-contract.md`](https://github.com/koolunkle-yak-allim/yak-allim-server/blob/main/docs/api-contract.md)
"n8n 연동 계약"이 기준입니다. Import와 자격 증명 설정은 [루트 README](../README.md#n8n-워크플로우)를 참고하세요.

## 현재 흐름

```
Webhook → Upstage OCR ─→ Code in JavaScript ─→ Basic LLM Chain ─→ 약품 추출 확인 ─true─→ Spring Boot
               │error            │error                │error            │false
               └─────────────────┴─────────────────────┴─────────────────┴──────────→ Spring Boot (실패)
```

- `Webhook`: 서버가 `?jobId={jobId}` 쿼리와 `multipart/form-data`의 `file` 필드로 이미지를 보냅니다.
- `Code in JavaScript`: OCR 응답을 LLM 입력으로 가공하고 `jobId`를 꺼냅니다.
- `약품 추출 확인`(IF): 약품이 하나 이상 추출됐는지 확인합니다.
- `Spring Boot`: 결과를 `POST http://yak-allim-nginx/api/v1/ocr/n8n/callback/{jobId}`로 보냅니다.
- `Spring Boot (실패)`: 중간 노드가 실패하거나 약품을 찾지 못하면 같은 주소로 `status: "FAILED"`를 보냅니다.

실패 콜백이 없으면 서버는 처리 시간 초과(기본 15분) 후에야 작업을 실패로 처리합니다.
아래는 각 노드의 설정과 그렇게 한 이유입니다.

## 1. Webhook 노드

- **Authentication**: `Header Auth`
  - Name: `X-N8N-WEBHOOK-SECRET`
  - Value: 서버의 `OCR_N8N_WEBHOOK_SECRET`과 같은 값
- **Respond**: `Immediately`(기본값)를 유지합니다.
  - `When Last Node Finishes`로 바꾸면 분석이 끝날 때까지 서버의 전송 스레드가 묶입니다.
  - 서버의 HTTP 타임아웃(60초)을 넘기면 전송 실패(`N8N_DISPATCH_FAILED`)로 처리됩니다.

## 2. 실패 처리 방식

n8n에서 실패를 처리하는 방법은 두 가지이며, 이 워크플로우는 **노드별 에러 출력**을 씁니다.

| 방식 | 장점 | 단점 |
| --- | --- | --- |
| **노드별 에러 출력** (사용) | 같은 실행 안에서 처리되어 `jobId`를 바로 꺼낼 수 있음 | 실패할 수 있는 노드마다 연결 필요 |
| Error Trigger + Error Workflow | 워크플로우 전체 실패를 한곳에서 받음 | 별도 실행이라 원래 요청의 `jobId`를 알기 어려움(n8n API로 실행 데이터 재조회 필요), production 실행에서만 동작 |

n8n이 멈추거나 재시작되는 등 콜백 자체를 보내지 못하는 경우는 서버의 처리 시간 초과가 처리합니다.

### 에러 출력 켜기

`Upstage OCR`, `Code in JavaScript`, `Basic LLM Chain` 각각에서:

- **Settings → On Error**를 `Continue (using error output)`로 설정합니다.
- 노드에 error 출력이 하나 더 생깁니다. 세 노드의 에러 출력을 모두 4번의 `Spring Boot (실패)` 노드로 모읍니다.

### LLM 결과 검증 (`약품 추출 확인` 노드)

LLM이 에러 없이 끝나도 결과를 쓸 수 없는 경우가 있습니다. 그래서 `Basic LLM Chain`과 `Spring Boot` 사이에
**IF 노드**를 두고, 약품이 하나도 추출되지 않았으면 실패 콜백으로 보냅니다.

- 조건(Number): `{{ ($json.output?.prescriptions ?? []).length }}` **is greater than** `0`
- true → `Spring Boot`, false → `Spring Boot (실패)`

서버는 빈 목록을 "약이 0개인 성공"으로 처리합니다. 실패로 보내야 사용자에게
"사진을 다시 찍어 올려 주세요"라는 안내가 나갑니다.

## 3. 성공 콜백 (`Spring Boot` 노드)

- 본문의 `status`는 계약 문서에 맞춰 `"COMPLETED"`를 보냅니다. 서버는 `FAILED`가 아니면 모두 성공으로 처리합니다.
- `medicines` 항목은 `medicineName`, `dosagePerTake`, `dailyFrequency`, `durationDays` 네 필드만 씁니다.
  `Structured Output Parser` 스키마와 LLM 프롬프트에도 이 네 필드만 있습니다.
  서버가 쓰지 않는 약품명 좌표(`bounds`)는 LLM 응답만 길게 하고 부정확한 값을 만들 수 있어 넣지 않습니다.
  OCR 좌표(`words_with_coordinates`)는 표에서 약품명과 숫자의 행을 맞추는 데 쓰도록 LLM 입력에 남겨 둡니다.
- **Settings → Retry On Fail**을 켭니다(Max Tries 3, Wait 5000ms). 서버가 블루-그린 전환 중이라 잠시 응답하지 못할 때를 대비합니다.

## 4. 실패 콜백 (`Spring Boot (실패)` 노드)

`Spring Boot` 노드를 복제한 HTTP Request 노드이며, 아래만 다릅니다.

- **URL**:
  ```
  =http://yak-allim-nginx/api/v1/ocr/n8n/callback/{{ $('Webhook').first().json.query.jobId }}
  ```
  `Upstage OCR`에서 실패하면 `Code in JavaScript`가 실행되지 않습니다. 그래서 jobId는 `Webhook` 노드에서 꺼냅니다.
- **Header**: `X-N8N-Secret` (`Spring Boot` 노드와 같은 값)
- **Body** (`JSON`):
  ```
  {{ JSON.stringify({
    jobId: $('Webhook').first().json.query.jobId,
    status: "FAILED",
    error: String(
      typeof $json.error === 'string'
        ? $json.error
        : ($json.error && ($json.error.message || JSON.stringify($json.error))) || '약품 정보를 추출하지 못함'
    ).slice(0, 500)
  }) }}
  ```
  - 문자열을 직접 이어 붙이지 않고 `JSON.stringify`를 씁니다. 에러 메시지에 따옴표나 줄바꿈이 있어도 JSON이 깨지지 않습니다.
  - 에러 출력의 `error`는 노드에 따라 문자열이기도 하고 `message`를 가진 객체이기도 해서 둘 다 처리합니다.
    `약품 추출 확인`의 false 경로처럼 `error`가 없으면 기본 문구를 보냅니다.
  - `??`와 `||`를 한 식에 섞지 마세요. n8n이 표현식을 변환하면서 괄호를 없애 `invalid syntax` 오류가 납니다(n8n 2.39 확인).
  - `error`는 서버 로그에만 남고 사용자에게는 보이지 않습니다. 그래도 OCR 원문 같은 처방 내용은 넣지 마세요.
- **Settings**
  - **Retry On Fail**: 켜기(Max Tries 3, Wait 5000ms)
  - **On Error**: `Continue`. 콜백 자체가 실패해도 에러 처리가 반복되지 않게 합니다.

## 5. 서버의 콜백 처리

| 상황 | 응답 | 서버 동작 |
| --- | --- | --- |
| 성공 콜백 | `200` | 작업 `COMPLETED`, SSE `COMPLETED`, FCM 완료 알림 |
| 실패 콜백 | `200` | 작업 `FAILED`, SSE `FAILED`, FCM `errorCode=N8N_PROCESSING_FAILED` |
| 이미 끝난 작업(취소, 시간 초과 등) | `200` | 무시 |
| 경로와 본문의 `jobId`가 다름 | `400` | - |
| secret 불일치 | `401` | - |

`status`는 대소문자를 구분하지 않으며, `FAILED`가 아니거나 생략하면 성공으로 처리됩니다.

## 6. 확인 방법

1. **서버만 먼저 확인**: 작업을 하나 올린 뒤 콜백을 직접 호출합니다.
   ```bash
   curl -X POST http://localhost:8082/api/v1/ocr/n8n/callback/<jobId> \
     -H "X-N8N-Secret: <secret>" -H "Content-Type: application/json" \
     -d '{"jobId":"<jobId>","status":"FAILED","error":"manual test"}'
   ```
   - 포트는 현재 활성 컨테이너(blue 8082 / green 8083)에 맞춥니다.
   - 이어서 `GET /api/v1/ocr/jobs/<jobId>`의 `status`가 `FAILED`인지 확인합니다.
   - 서버 로그에 `n8n reported analysis failure`가 찍히는지도 확인합니다.
2. **n8n 연동 확인**: `Upstage OCR` 자격 증명을 일부러 틀리게 바꾸고 실제 사진을 올립니다.
   n8n 실행 화면에서 `Spring Boot (실패)` 노드가 `200`을 받았는지 확인합니다.
3. **빈 결과 확인**: 약 정보가 없는 사진을 올려 `약품 추출 확인` 노드가 실패 경로로 가는지 확인합니다.
4. **주의**: `webhook-test` 주소는 n8n 편집기에서 "Listen for test event"를 누른 동안에만 동작합니다.
   최종 확인은 워크플로우를 Active로 켠 상태에서 production 주소(`/webhook/ocr`)로 하세요.

설정을 바꾼 뒤에는 워크플로우를 다시 export해 `workflows/ocr.json`을 갱신하세요.
export한 파일에 secret 값이 들어 있지 않은지(`REPLACE_WITH_...`로 되돌렸는지)도 확인합니다.
