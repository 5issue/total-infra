import { createStore } from "zustand/vanilla";

/**
 * Access Token 메모리 보관 (Store Provider 패턴, 뼈대).
 *
 * ⚠️ 보안 (security-convention FE-01 / FE-05):
 * - Access Token 은 "메모리에만" 둔다. localStorage / sessionStorage / JS 접근 가능한 쿠키 금지.
 * - Refresh Token 은 HttpOnly + Secure 쿠키(서버 Route Handler 관리). 이 스토어에 두지 않는다.
 * - apiClient 의 401 인터셉터가 이 스토어를 읽어 Authorization 헤더를 채우고,
 *   재발급 성공 시 setAccessToken 으로 갱신한다.
 * - uiStore 와 동일하게 Provider(useRef) 로 마운트당 1회 생성한다.
 */

export type AuthTokenState = {
  accessToken: string | null;
};

export type AuthTokenActions = {
  setAccessToken: (token: string) => void;
  clear: () => void;
};

export type AuthTokenStore = AuthTokenState & AuthTokenActions;

export const defaultAuthTokenState: AuthTokenState = {
  accessToken: null,
};

export const createAuthTokenStore = (
  initState: AuthTokenState = defaultAuthTokenState,
) => {
  return createStore<AuthTokenStore>()((set) => ({
    ...initState,
    setAccessToken: (token) => set({ accessToken: token }),
    clear: () => set(defaultAuthTokenState),
  }));
};

export type AuthTokenStoreApi = ReturnType<typeof createAuthTokenStore>;
