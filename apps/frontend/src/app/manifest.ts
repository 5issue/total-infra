import type { MetadataRoute } from "next";

/**
 * App Router 네이티브 manifest. public/manifest.json 정적 파일을 쓰지 않는다.
 * 빌드 시 /manifest.webmanifest 로 서빙된다.
 *
 * icons 의 실제 파일(public/icon-*.png)은 디자인 파트 확정 후 추가 예정 (⏳).
 */
export default function manifest(): MetadataRoute.Manifest {
  return {
    name: "total-client",
    short_name: "total-client",
    description: "통합 이커머스 프론트엔드",
    start_url: "/",
    display: "standalone",
    background_color: "#ffffff",
    theme_color: "#4f46e5",
    icons: [
      { src: "/icon-192.png", sizes: "192x192", type: "image/png" },
      { src: "/icon-512.png", sizes: "512x512", type: "image/png" },
    ],
  };
}
