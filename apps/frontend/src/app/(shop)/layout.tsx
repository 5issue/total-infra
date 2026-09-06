import type { ReactNode } from "react";

/**
 * (shop) 셸: Header(+장바구니 아이콘) / BottomNav(홈·검색·AI·마이컬리).
 * 실제 Header/BottomNav 는 components/organisms/shared 에서 구현 예정.
 */
export default function ShopLayout({ children }: { children: ReactNode }) {
  return (
    <div className="mx-auto flex min-h-dvh max-w-screen-sm flex-col">
      {/* TODO: <Header /> — components/organisms/shared */}
      <main className="flex-1">{children}</main>
      {/* TODO: <BottomNav /> — components/organisms/shared */}
    </div>
  );
}
