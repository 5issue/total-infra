/** 앱 전역 상수. */

export const APP_NAME = "total-client";

/** BottomNav 4탭 */
export const BOTTOM_NAV = [
  { href: "/", label: "홈" },
  { href: "/search", label: "검색" },
  { href: "/ai", label: "AI" },
  { href: "/mypage", label: "마이컬리" },
] as const;

/** OAuth 소셜 로그인 제공자 */
export const OAUTH_PROVIDERS = ["kakao", "naver"] as const;
