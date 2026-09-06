"use client";

import { useContext } from "react";
import { useStore } from "zustand";
import { useShallow } from "zustand/react/shallow";
import { UIStoreContext } from "@/providers/UIStoreProvider";
import type { UIStore } from "@/stores/uiStore";

function useUIStoreApi() {
  const store = useContext(UIStoreContext);
  if (!store) {
    throw new Error("useUIStore 는 <UIStoreProvider> 내부에서만 사용할 수 있습니다.");
  }
  return store;
}

/**
 * 단일 원시값 selector 전용.
 * 예: const isOpen = useUIStore((s) => s.isCartDrawerOpen);
 */
export function useUIStore<T>(selector: (state: UIStore) => T): T {
  return useStore(useUIStoreApi(), selector);
}

/**
 * 배열/객체를 반환하는 selector 전용.
 * useShallow 를 강제로 감싸 참조만 바뀐 리렌더를 막는다.
 * 예: const { openMobileNav, closeMobileNav } =
 *       useUIStoreShallow((s) => ({ openMobileNav: s.openMobileNav, closeMobileNav: s.closeMobileNav }));
 */
export function useUIStoreShallow<T>(selector: (state: UIStore) => T): T {
  return useStore(useUIStoreApi(), useShallow(selector));
}
