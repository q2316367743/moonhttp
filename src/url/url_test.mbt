///|
/// 绝对地址判定要覆盖三类边界：正常 scheme、协议相对地址、冒号但非 scheme。
test "is_absolute_url recognises schemes" {
  assert_true(@url.is_absolute_url("https://example.com/users"))
  assert_true(@url.is_absolute_url("http://example.com"))
  assert_true(@url.is_absolute_url("ftp://example.com/f"))
  // scheme 大小写不敏感
  assert_true(@url.is_absolute_url("HTTPS://example.com"))
  // 协议相对地址：axios 的正则里 scheme 可选，所以这也算绝对地址
  assert_true(@url.is_absolute_url("//cdn.example.com/lib.js"))
}

///|
/// 相对地址、以及「含冒号但不是 scheme」的地址都必须判为相对，
/// 否则 `localhost:8080` 这种地址会被误当成绝对地址而跳过 base_url 拼接。
test "is_absolute_url rejects relative urls" {
  assert_false(@url.is_absolute_url("/users"))
  assert_false(@url.is_absolute_url("users"))
  assert_false(@url.is_absolute_url("./users"))
  assert_false(@url.is_absolute_url("../users"))
  assert_false(@url.is_absolute_url("localhost:8080/users"))
  assert_false(@url.is_absolute_url("mailto:a@b.com"))
  assert_false(@url.is_absolute_url(""))
}

///|
/// scheme 必须以字母开头，且只允许字母、数字与 `+` `-` `.`。
test "is_absolute_url validates scheme grammar" {
  assert_false(@url.is_absolute_url("1http://example.com"))
  assert_false(@url.is_absolute_url("-http://example.com"))
  assert_true(@url.is_absolute_url("a+b-c.d://example.com"))
}

///|
/// 拼接规则：去掉 base 的尾斜杠与相对路径的首斜杠，中间补恰好一个 `/`。
test "combine_urls inserts exactly one slash" {
  assert_eq(
    @url.combine_urls("https://api.example.com", "/users"),
    "https://api.example.com/users",
  )
  assert_eq(
    @url.combine_urls("https://api.example.com/", "users"),
    "https://api.example.com/users",
  )
  assert_eq(
    @url.combine_urls("https://api.example.com///", "//users"),
    "https://api.example.com/users",
  )
  // base 带路径时同样只在接缝处补一个斜杠
  assert_eq(
    @url.combine_urls("https://api.example.com/api/", "/v1/users"),
    "https://api.example.com/api/v1/users",
  )
  // 相对路径为空时原样返回 base
  assert_eq(
    @url.combine_urls("https://api.example.com/", ""),
    "https://api.example.com/",
  )
}

///|
/// build_full_path 的四种分支：相对路径拼接、绝对路径直连、
/// 关掉绝对地址直连后强制拼接、没有 base_url 时原样返回。
test "build_full_path covers every branch" {
  let base = Some("https://api.example.com")
  assert_eq(
    @url.build_full_path(base, Some("/users"), None),
    Some("https://api.example.com/users"),
  )
  assert_eq(
    @url.build_full_path(base, Some("https://other.example.com/x"), None),
    Some("https://other.example.com/x"),
  )
  // allow_absolute_urls = false：即使 url 是绝对地址也拼到 base_url 后面
  assert_eq(
    @url.build_full_path(base, Some("https://other.example.com/x"), Some(false)),
    Some("https://api.example.com/https://other.example.com/x"),
  )
  assert_eq(@url.build_full_path(None, Some("/users"), None), Some("/users"))
  // 空串 base_url 视同不存在（复刻 axios 里 `if (baseURL && ...)` 的 falsy 判断）
  assert_eq(
    @url.build_full_path(Some(""), Some("/users"), None),
    Some("/users"),
  )
  assert_eq(@url.build_full_path(base, None, None), None)
}

///|
/// 保留字符集与 axios 一致：字母数字与 `-_.*` 不转义，
/// `~` 反而要转义（这是 axios 在 encodeURIComponent 之外额外做的），空格写 `+`。
test "encode_component keeps and escapes the axios character set" {
  assert_eq(@url.encode_component("abcXYZ019-_.*"), "abcXYZ019-_.*")
  assert_eq(@url.encode_component("~"), "%7E")
  assert_eq(@url.encode_component("a b"), "a+b")
  assert_eq(@url.encode_component("a[]"), "a%5B%5D")
  assert_eq(@url.encode_component("a!'()"), "a%21%27%28%29")
  assert_eq(@url.encode_component("a&b=c"), "a%26b%3Dc")
  assert_eq(@url.encode_component("a/b:c"), "a%2Fb%3Ac")
}

///|
/// 非 ASCII 必须按 UTF-8 字节转义，且十六进制为大写。
test "encode_component encodes utf8 bytes in upper case" {
  assert_eq(@url.encode_component("中"), "%E4%B8%AD")
  assert_eq(@url.encode_component("中文"), "%E4%B8%AD%E6%96%87")
  // 代理对（emoji）不能被 UTF-16 码元拆开
  assert_eq(@url.encode_component("😀"), "%F0%9F%98%80")
}

///|
/// 数组默认序列化为 `key[]=v` 形式；注意方括号本身会被百分号编码，
/// axios 的真实输出就是 `tags%5B%5D=a`，不是字面的 `tags[]=a`。
test "serialize_params renders arrays with encoded brackets" {
  assert_eq(@url.serialize_params({ "foo": "bar" }), "foo=bar")
  assert_eq(
    @url.serialize_params({ "tags": ["a", "b"] }),
    "tags%5B%5D=a&tags%5B%5D=b",
  )
}

///|
/// 嵌套对象用 `key[sub]`，数组里的对象再加下标。
test "serialize_params renders nested objects" {
  assert_eq(
    @url.serialize_params({ "filter": { "status": 1 } }),
    "filter%5Bstatus%5D=1",
  )
  assert_eq(
    @url.serialize_params({ "items": [{ "id": 1 }] }),
    "items%5B0%5D%5Bid%5D=1",
  )
  assert_eq(
    @url.serialize_params({ "a": { "b": { "c": "d" } } }),
    "a%5Bb%5D%5Bc%5D=d",
  )
}

///|
/// null 一律跳过：既不写成 `key=`，也不写成 `key=null`。
test "serialize_params skips nulls" {
  assert_eq(@url.serialize_params({ "a": Json::null() }), "")
  assert_eq(@url.serialize_params({ "a": Json::null(), "b": "1" }), "b=1")
  assert_eq(
    @url.serialize_params({ "tags": [Json::null(), "x"] }),
    "tags%5B%5D=x",
  )
}

///|
/// 布尔与数字按字面量渲染；数字优先用 Json 保留的原始书写形式。
test "serialize_params renders booleans and numbers" {
  assert_eq(@url.serialize_params({ "a": true, "b": false }), "a=true&b=false")
  assert_eq(@url.serialize_params({ "page": 1 }), "page=1")
}

///|
/// 键与值都会被编码。
test "serialize_params encodes keys as well as values" {
  assert_eq(@url.serialize_params({ "a b": "x y" }), "a+b=x+y")
  assert_eq(@url.serialize_params({ "a&b": "c" }), "a%26b=c")
}

///|
/// 顶层不是对象时没有合法的 query 语义，返回空串。
test "serialize_params ignores non object roots" {
  assert_eq(@url.serialize_params([1, 2]), "")
  assert_eq(@url.serialize_params("x"), "")
  assert_eq(@url.serialize_params(Json::null()), "")
}

///|
/// 追加 query 时的三个边界：空参数不留 `?`、已有 `?` 用 `&`、fragment 被丢弃。
test "build_url appends query string" {
  assert_eq(@url.build_url("/foo", None), "/foo")
  assert_eq(@url.build_url("/foo", Some({})), "/foo")
  assert_eq(@url.build_url("/foo", Some({ "foo": "bar" })), "/foo?foo=bar")
  assert_eq(
    @url.build_url("/foo?query=baz", Some({ "foo": "bar" })),
    "/foo?query=baz&foo=bar",
  )
  // fragment 被丢弃，与 axios 的实现一致
  assert_eq(
    @url.build_url("/foo#section", Some({ "foo": "bar" })),
    "/foo?foo=bar",
  )
  // null 值全部被跳过，等价于没有参数
  assert_eq(@url.build_url("/foo", Some({ "a": Json::null() })), "/foo")
}

///|
/// 冒号在开头（空 scheme）或 scheme 后不是 `//` 时都不算绝对地址。
test "is_absolute_url rejects empty and malformed schemes" {
  assert_false(@url.is_absolute_url(":foo"))
  assert_false(@url.is_absolute_url("://example.com"))
  assert_false(@url.is_absolute_url("http:/example.com"))
}

///|
/// 超出 Double 精度的大整数会被 `@json.parse` 记下原始文本（`Json::Number` 的
/// `repr` 字段），序列化时应当沿用它，否则会丢精度并变成科学计数法。
test "serialize_params preserves big integer literals" {
  let params = @json.parse("{\"id\": 123456789012345678901234567890}")
  assert_eq(@url.serialize_params(params), "id=123456789012345678901234567890")
}

///|
/// 调用方显式给出的 `repr` 同样优先于 Double 的默认格式化。
test "serialize_params honours explicit number repr" {
  let params : Json = {
    "price": Json::number(1.5, repr="1.50"),
    "count": Json::number(1000.0),
  }
  assert_eq(@url.serialize_params(params), "price=1.50&count=1000")
}
