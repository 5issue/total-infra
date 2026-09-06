import { createStore } from "zustand/vanilla";

/**
 * 필터 바텀시트(FilterSheet)의 임시 선택값 (클라 UI 상태, 뼈대).
 *
 * - 시트가 열려 있는 동안의 "미적용" 선택을 담는다. "적용" 시 URL(searchParams)로 커밋.
 * - uiStore 와 동일하게 Provider(useRef) + useShallow 훅 패턴으로 마운트당 1회 생성한다.
 * - 실제 필터 축(카테고리/배송타입/가격대 등)은 필터 스펙 확정 후 추가 (structure-convention §6).
 */

export type FilterUIState = {
  /** 적용 전 임시 선택값. key = 필터 그룹 id, value = 선택된 옵션 id 배열 */
  draft: Record<string, string[]>;
};

export type FilterUIActions = {
  toggleOption: (groupId: string, optionId: string) => void;
  clearGroup: (groupId: string) => void;
  reset: () => void;
};

export type FilterUIStore = FilterUIState & FilterUIActions;

export const defaultFilterUIState: FilterUIState = {
  draft: {},
};

export const createFilterUIStore = (
  initState: FilterUIState = defaultFilterUIState,
) => {
  return createStore<FilterUIStore>()((set) => ({
    ...initState,
    toggleOption: (groupId, optionId) =>
      set((state) => {
        const current = state.draft[groupId] ?? [];
        const next = current.includes(optionId)
          ? current.filter((id) => id !== optionId)
          : [...current, optionId];
        return { draft: { ...state.draft, [groupId]: next } };
      }),
    clearGroup: (groupId) =>
      set((state) => {
        const { [groupId]: _removed, ...rest } = state.draft;
        return { draft: rest };
      }),
    reset: () => set(defaultFilterUIState),
  }));
};

export type FilterUIStoreApi = ReturnType<typeof createFilterUIStore>;
