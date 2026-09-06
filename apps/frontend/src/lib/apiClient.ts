/**
 * HTTP 클라이언트 (구현 예정).
 *
 * - fetch 래퍼: publicFetch / privateFetch (api-convention §3)
 * - 401 응답 시 Access Token 재발급 인터셉터 (AUTH-001)
 * - 응답을 types/<domain> 의 Zod 스키마로 parse 후 반환
 *
 * 상세 규칙: .agents/api-convention/SKILLS.md
 */
export type RequestOptions = RequestInit & {
  /** true 면 privateFetch(인증 필요), 기본 false */
  auth?: boolean;
};
