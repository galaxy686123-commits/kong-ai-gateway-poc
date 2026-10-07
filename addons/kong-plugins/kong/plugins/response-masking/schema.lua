local typedefs = require "kong.db.schema.typedefs"

return {
  name = "response-masking",
  fields = {
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
          -- 가릴 종류: ip 사설 IP · api_key API 키(sk- · AKIA · ghp_ · xox) · db_url 접속 주소 속 계정 · password 비밀번호 값
          { types = { type = "set", default = { "ip", "api_key", "db_url", "password" },
                      elements = { type = "string", one_of = { "ip", "api_key", "db_url", "password" } } } },
        },
    } },
  },
}
