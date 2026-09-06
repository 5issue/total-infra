import { z } from "zod";

/**
 * 런타임 타입 안전 환경변수.
 *
 * ⚠️ NEXT_PUBLIC_* 는 "빌드 타임에 번들로 인라인"된다.
 *    - 배포 후 Kubernetes ConfigMap 값을 바꿔도 이미 빌드된 브라우저 번들은 바뀌지 않는다.
 *    - 값을 바꾸려면 이미지를 다시 빌드해야 한다.
 *    - 그래서 Dockerfile 의 builder 스테이지에서 ARG/ENV 로 주입한다.
 *
 * 반면 접두어 없는 값(API_INTERNAL_URL 등)은 서버(Node)에서만 process.env 로 읽히며
 * 런타임에 ConfigMap/Secret 으로 주입할 수 있다. 브라우저 번들에는 포함되지 않는다.
 *
 * Next 는 NEXT_PUBLIC_* 를 "정적 참조"일 때만 인라인하므로 process.env.NEXT_PUBLIC_X
 * 형태로 하나씩 명시적으로 읽어야 한다 (동적 접근 금지).
 */

const clientSchema = z.object({
  NEXT_PUBLIC_API_URL: z.string().url(),
  NEXT_PUBLIC_APP_ENV: z.enum(["local", "development", "staging", "production"]),
});

const serverSchema = z.object({
  API_INTERNAL_URL: z.string().url(),
});

const clientParsed = clientSchema.safeParse({
  NEXT_PUBLIC_API_URL: process.env.NEXT_PUBLIC_API_URL,
  NEXT_PUBLIC_APP_ENV: process.env.NEXT_PUBLIC_APP_ENV,
});

if (!clientParsed.success) {
  throw new Error(
    `[env] 잘못된 클라이언트 환경변수:\n${clientParsed.error.issues
      .map((i) => `  - ${i.path.join(".")}: ${i.message}`)
      .join("\n")}`,
  );
}

const isServer = typeof window === "undefined";

let serverEnv: z.infer<typeof serverSchema> | null = null;
if (isServer) {
  const serverParsed = serverSchema.safeParse({
    API_INTERNAL_URL: process.env.API_INTERNAL_URL,
  });
  if (!serverParsed.success) {
    throw new Error(
      `[env] 잘못된 서버 환경변수:\n${serverParsed.error.issues
        .map((i) => `  - ${i.path.join(".")}: ${i.message}`)
        .join("\n")}`,
    );
  }
  serverEnv = serverParsed.data;
}

export const env = {
  ...clientParsed.data,
  /** 서버 전용. 브라우저에서 접근하면 throw. */
  get API_INTERNAL_URL(): string {
    if (!serverEnv) {
      throw new Error("[env] API_INTERNAL_URL 은 서버에서만 접근할 수 있습니다.");
    }
    return serverEnv.API_INTERNAL_URL;
  },
} as const;

export type Env = typeof env;
