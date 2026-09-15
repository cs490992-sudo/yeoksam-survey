import type { SurveyTemplate } from '../types/survey'

// The Nanta presets intentionally retain their established five-point scale.
const question = (domain: string, question_text: string) => ({ domain, question_text, response_type: 'face_5' as const, is_required: true, options: [], image_path: null })
export const defaultSurveyTemplates: SurveyTemplate[] = [
  { key: 'blank-single', name: '새 단회 조사', description: '질문을 직접 구성하는 빈 단회 조사', survey_type: 'single', title: '', questions: [] },
  { key: 'blank-pre-post', name: '새 사전·사후 조사', description: '동일 문항으로 전후를 비교하는 빈 조사', survey_type: 'pre_post', title: '', questions: [] },
  { key: 'dodream-nanta-pre-post', name: '두드림 난타 사전·사후 비교조사', description: '기관용 초기 권장 문항이며 표준화된 임상 평가도구가 아닙니다.', survey_type: 'pre_post', title: '두드림 난타 사전·사후 비교조사', questions: [
    question('자기표현', '나는 내 생각이나 느낌을 말이나 몸짓으로 표현할 수 있어요.'), question('자기표현', '나는 다른 사람 앞에서 자신 있게 활동할 수 있어요.'), question('자기표현', '나는 내가 원하는 것을 선택하고 표현할 수 있어요.'),
    question('사회적 상호작용', '나는 다른 사람과 순서를 맞추며 활동할 수 있어요.'), question('사회적 상호작용', '나는 친구나 선생님의 소리를 듣고 함께 연주할 수 있어요.'), question('사회적 상호작용', '나는 활동 중 다른 사람과 즐겁게 어울릴 수 있어요.'),
  ] },
  { key: 'dodream-nanta-performance', name: '두드림 난타 공연 후 만족도 조사', description: '기관용 초기 권장 문항이며 표준화된 임상 평가도구가 아닙니다.', survey_type: 'single', title: '두드림 난타 공연 후 만족도 조사', questions: [
    question('공연 경험', '오늘 공연이 즐거웠나요?'), question('공연 경험', '공연을 마친 뒤 뿌듯했나요?'), question('공연 경험', '사람들 앞에서 연주한 내가 자랑스러웠나요?'), question('공연 경험', '공연할 때 자신감이 생겼나요?'), question('공연 경험', '다음에도 공연에 참여하고 싶나요?'),
  ] },
]
