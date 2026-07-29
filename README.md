# 역삼 만족도 조사 (Yeoksam Survey)

React/TypeScript/Vite와 Supabase Auth로 만든 역삼주간보호센터 만족도 조사 PWA입니다.

## 실행

```bash
npm install
cp .env.example .env.local
npm run dev
npm run typecheck
npm run build
```

`VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY`에는 publishable/anon 값만 사용합니다. service role 키를 브라우저에 넣지 않습니다.

## 2차 구현 범위

- 조사 프로젝트, 회차, 문항/선택지, 참여자 및 차기 응답 테이블 migration과 조직 기반 RLS
- 새 조사 3단계 생성, 초안 저장/시작, 초안 수정, 목록 검색/필터와 상태 관리
- 공유 `clients`, `programs` 조회 adapter와 두드림 난타 사전·사후/공연 후 프리셋
- 실제 데이터 기반 대시보드 최소 통계

`supabase/migrations/001_survey_core.sql`은 **자동 실행되지 않습니다.** 운영 적용 전에 `profiles`, `clients`, `programs`의 실제 컬럼과 UUID 타입을 확인해야 합니다. 공유 테이블에는 FK나 변경을 적용하지 않습니다.

이용인의 실제 응답 진행/저장, 완료 현황, 결과 분석과 보고서는 3·4차 작업 범위입니다. 현재 프리셋 문항은 기관용 초기 권장 문항이며 표준화된 임상 평가도구가 아닙니다.
