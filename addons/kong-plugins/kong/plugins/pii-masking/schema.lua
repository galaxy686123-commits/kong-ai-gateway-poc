local typedefs = require "kong.db.schema.typedefs"

return {
  name = "pii-masking",
  fields = {
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
          -- 가릴 종류: rrn 주민·외국인등록번호 · card 카드 · mobile 휴대전화 · landline 유선전화 · account 계좌 · email 이메일
          { types = { type = "set", default = { "rrn", "card", "mobile", "landline", "account", "email" },
                      elements = { type = "string", one_of = { "rrn", "card", "mobile", "landline", "account", "email" } } } },
          { response_header = { type = "boolean", default = true } },   -- 가린 종류를 X-PII-Masked 헤더로 알림
        },
    } },
  },
}
