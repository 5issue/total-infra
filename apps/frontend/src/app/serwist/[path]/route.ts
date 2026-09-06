import { createSerwistRoute } from "@serwist/turbopack";

/**
 * @serwist/turbopack 은 Route Handler 방식이다.
 * createSerwistRoute() 가 반환하는 5개 export 를 모두 그대로 내보내야 동작한다.
 *
 * - swSrc: 서비스 워커 소스의 "실제 경로". src/ 디렉터리를 쓰므로 "src/app/sw.ts".
 * - useNativeEsbuild: esbuild(네이티브) 로 SW 를 번들. devDependencies 에 esbuild 명시.
 *
 * layout.tsx 의 <SerwistProvider swUrl="/serwist/sw.js" /> 와 경로가 일치해야 한다.
 */
export const { dynamic, dynamicParams, revalidate, generateStaticParams, GET } =
  createSerwistRoute({
    swSrc: "src/app/sw.ts",
    useNativeEsbuild: true,
  });
