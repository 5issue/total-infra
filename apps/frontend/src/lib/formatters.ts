/** 가격/날짜 등 표시 포맷 유틸. 필요에 따라 확장한다. */

export const formatPrice = (won: number): string =>
  `${Math.round(won).toLocaleString("ko-KR")}원`;

export const formatDate = (value: string | number | Date): string =>
  new Intl.DateTimeFormat("ko-KR", { dateStyle: "medium" }).format(
    new Date(value),
  );
