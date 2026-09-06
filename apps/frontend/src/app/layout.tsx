import type { Metadata, Viewport } from "next";
import { SerwistProvider } from "@serwist/turbopack/react";
import type { ReactNode } from "react";
import { Providers } from "./providers";
import "@/styles/globals.css";

export const metadata: Metadata = {
  title: {
    default: "total-client",
    template: "%s | total-client",
  },
  description: "통합 이커머스 프론트엔드",
  applicationName: "total-client",
};

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  // 접근성: user-scalable=no / maximum-scale 로 확대를 막지 않는다.
  // 브라우저 크롬 색상 라이트/다크 분기. 값은 globals.css --background 와 동일하게 유지.
  // (임시 그레이스케일 — 디자인 토큰 확정 시 교체)
  themeColor: [
    { media: "(prefers-color-scheme: light)", color: "#ffffff" },
    { media: "(prefers-color-scheme: dark)", color: "#0a0a0a" },
  ],
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    // suppressHydrationWarning: 다음 단계에서 테마 토글 스크립트가 <html> 에
    // data-theme 를 주입해도 hydration 경고가 나지 않도록.
    <html lang="ko" dir="ltr" suppressHydrationWarning>
      <body>
        {/* swUrl 은 반드시 src/app/serwist/[path]/route.ts 의 경로와 일치해야 한다. */}
        <SerwistProvider swUrl="/serwist/sw.js">
          <Providers>{children}</Providers>
        </SerwistProvider>
      </body>
    </html>
  );
}
