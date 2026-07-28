# 역삼 만족도 조사 (Yeoksam Survey)

역삼주간보호센터 이용인을 위한 독립 만족도 조사 웹앱/PWA의 1차 기반입니다. 향후 일반 단회, 공연·행사 후 단회, 프로그램 사전·사후 비교조사를 지원합니다.

## 기술 스택과 실행

- React 19, TypeScript(strict), Vite, React Router
- Supabase JavaScript SDK(Auth 및 기존 profiles 연동 기반)
- vite-plugin-pwa(설치 manifest, 정적 앱 셸 서비스 워커)

    npm install
    cp .env.example .env.local
    npm run dev
    npm run typecheck
    npm run build
    npm run preview

## 환경 변수

VITE_SUPABASE_URL, VITE_SUPABASE_PUBLISHABLE_KEY, VITE_ATTENDANCE_APP_URL, VITE_VOTING_APP_URL을 사용합니다. 앞의 두 값이 없으면 로그인 화면에 설정 안내가 표시됩니다. 브라우저에 노출되는 VITE_ 변수에는 **publishable/anon 키만** 사용하며 service role key, 관리자 키, 운영 비밀값은 절대 커밋하지 마세요.

## Vercel 배포

저장소를 Vercel에 연결하고 위 환경 변수를 프로젝트 설정에 등록합니다. Build Command는 npm run build, Output Directory는 dist입니다. vercel.json은 SPA 경로를 index.html로 돌립니다.

## 1차 범위

로그인과 세션 유지, 기존 profiles 기반 admin/staff 접근 제어, 보호 라우트, 그룹형 반응형 앱 셸, placeholder 페이지, 공통 UI, 설치 및 업데이트 안내를 포함합니다. 기존 출석·투표 앱과 같은 Supabase 프로젝트를 사용할 수 있지만 이 저장소는 테이블이나 원격 설정을 변경하지 않습니다.

아직 조사 생성·저장, 참여자/사진 조회, 응답, 완료 현황, 분석, 실제 보고서, 비밀번호 찾기, 가입은 구현하지 않았습니다. migration이나 SQL 파일도 포함하지 않습니다. 상세 개발 순서는 [로드맵](docs/ROADMAP.md), 향후 구조는 [데이터 모델 계획](docs/DATA_MODEL_PLAN.md)을 참고하세요.
