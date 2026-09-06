"use client";

import { createContext, useRef, type ReactNode } from "react";
import { createUIStore, type UIStoreApi } from "@/stores/uiStore";

/**
 * UI 스토어 Provider.
 * useRef 로 마운트당 1회만 store 인스턴스를 만든다 (모듈 싱글턴 금지).
 * 실제 selector 훅은 @/hooks/useUIStore 에서 제공한다.
 */
export const UIStoreContext = createContext<UIStoreApi | null>(null);

export function UIStoreProvider({ children }: { children: ReactNode }) {
  const storeRef = useRef<UIStoreApi | null>(null);
  storeRef.current ??= createUIStore();

  return (
    <UIStoreContext.Provider value={storeRef.current}>
      {children}
    </UIStoreContext.Provider>
  );
}
