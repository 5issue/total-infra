import {
  QueryClient,
  defaultShouldDehydrateQuery,
  isServer,
} from "@tanstack/react-query";

/**
 * 서버 상태 전용 QueryClient 팩토리.
 *
 * 원칙:
 * - 서버: 요청마다 새 QueryClient (요청 간 캐시 격리).
 * - 브라우저: 최초 1회만 생성한 뒤 재사용 (HMR / Suspense 중복 생성 방지).
 * - 클라이언트 UI 상태는 절대 여기 두지 않는다 -> Zustand 담당.
 */
function makeQueryClient(): QueryClient {
  return new QueryClient({
    defaultOptions: {
      queries: {
        staleTime: 60 * 1000,
      },
      dehydrate: {
        shouldDehydrateQuery: (query) =>
          defaultShouldDehydrateQuery(query) || query.state.status === "pending",
      },
    },
  });
}

let browserQueryClient: QueryClient | undefined;

export function getQueryClient(): QueryClient {
  if (isServer) {
    return makeQueryClient();
  }
  browserQueryClient ??= makeQueryClient();
  return browserQueryClient;
}
