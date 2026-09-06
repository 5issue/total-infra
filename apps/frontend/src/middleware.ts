import { type NextRequest, NextResponse } from "next/server";

/**
 * 인증 가드 (구현 예정).
 * 미인증 사용자가 /checkout, /mypage 하위 경로 접근 시 /login?redirect= 로 이동.
 * 실제 인가는 서버(Route Handler / 외부 API)가 매 요청 검증한다 — 이 미들웨어는 UX 목적.
 * (security-convention FE-15 참고)
 */
export function middleware(_req: NextRequest) {
  return NextResponse.next();
}

export const config = {
  matcher: ["/checkout/:path*", "/mypage/:path*"],
};
