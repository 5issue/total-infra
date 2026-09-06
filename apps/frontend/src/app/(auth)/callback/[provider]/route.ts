import { type NextRequest, NextResponse } from "next/server";

/**
 * OAuth 콜백 (provider: kakao | naver).
 * 인가 코드 → 토큰 교환 → 세션 쿠키 설정 로직은 구현 예정.
 */
export async function GET(
  _req: NextRequest,
  { params }: { params: Promise<{ provider: string }> },
) {
  const { provider } = await params;
  return NextResponse.json(
    { provider, status: "not-implemented" },
    { status: 501 },
  );
}
