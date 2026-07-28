# 향후 데이터 모델 계획

> 설계 검토용 문서입니다. 이 단계에서는 SQL 또는 migration을 만들거나 실행하지 않습니다.

## 예상 테이블

- survey_projects: 조사 정의와 유형
- survey_rounds: 단회·사전·사후 회차와 기간
- survey_questions: 문항과 응답 유형
- survey_question_options: 선택형 문항 보기
- survey_participants: 회차별 참여 대상
- survey_submissions: 이용인의 제출·완료 상태
- survey_answers: 문항별 응답

모든 조사 리소스는 organization_id를 가져 기관 사이 데이터를 분리합니다. 기존 profiles의 사용자·역할·기관 정보와 연결하고, 기존 clients, programs는 식별자 참조를 우선 검토하여 이용인·프로그램 정보를 중복 저장하지 않습니다.

survey_projects 하나에 단회 또는 사전·사후 survey_rounds를 연결합니다. 사전·사후는 같은 문항 버전을 사용하도록 고정하는 방안을 검토합니다. 참여자·회차 조합과 제출 제약으로 중복 응답을 막고, 완료 후 수정은 권한, 사유, 감사 기록을 요구하도록 설계합니다.

영구 삭제는 관리자에게도 제한하고 보관·비활성화를 기본으로 합니다. 조직 분리, 역할별 읽기/쓰기, 사진 및 개인정보 접근을 위해 모든 테이블에 RLS가 필요합니다. 실제 제약조건, 정책, SQL은 다음 작업에서 기존 schema와 권한을 확인한 뒤 별도 검토하여 생성합니다.
