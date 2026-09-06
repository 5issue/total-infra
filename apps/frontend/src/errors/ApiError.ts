/**
 * 공용 응답 포맷 `{ statusCode, message, data }` 의 에러 봉투를 표현한다.
 * api-client 는 실패 응답을 이 에러로 변환해 throw → query hook 의 `error` 로 전달.
 * (api-convention §6 참고)
 */
export class ApiError extends Error {
  constructor(
    readonly statusCode: number,
    message: string,
  ) {
    super(message);
    this.name = "ApiError";
  }
}
