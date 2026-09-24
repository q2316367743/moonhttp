// 请求体的用例：三种 `with_data_from_*` 的序列化结果，以及表单的 multipart 编码。
//
// 断言直接打在字节上：这些字节就是真正会写到连接上的东西，
// 而中间任何一层「看起来对」的转换都不算数。

///|
/// 从 `multipart/form-data; boundary=...` 里取出 boundary。
///
/// 测试要拿它拼期望正文（boundary 每次序列化都随机，写不死），
/// 因此这条同时也验证了「头里声明的分隔符」与「正文里用的分隔符」是同一个。
fn boundary_of(content_type : String) -> String {
  content_type.after("boundary=").unwrap().to_owned()
}

///|
/// 原样文本：字节就是文本的 UTF-8 编码，且**不推断** Content-Type
/// （调用方可能发的是纯文本，也可能是自己序列化好的载体）。
test "raw body is sent verbatim without content type" {
  let serialized = @config.Config::default()
    .with_data_from_str("a=1&b=2")
    .serialize_body()
  assert_eq(serialized.bytes, Some(b"a=1&b=2"))
  assert_eq(serialized.content_type, None)
}

///|
/// JSON：`stringify()` 后发送，并给出 `application/json`。
///
/// 关键是字符串值与 `with_data_from_str` 的分水岭：`with_data_from_json("hi")`
/// 发出去的是**合法 JSON 字面量** `"hi"`（带引号），而不是裸文本。
test "json body is stringified and declares application/json" {
  let object = @config.Config::default()
    .with_data_from_json({ "name": "moon" })
    .serialize_body()
  assert_eq(object.bytes, Some(b"{\"name\":\"moon\"}"))
  assert_eq(object.content_type, Some("application/json"))
  let text = @config.Config::default()
    .with_data_from_json("hi")
    .serialize_body()
  assert_eq(text.bytes, Some(b"\"hi\""))
  assert_eq(text.content_type, Some("application/json"))
  // 数组、数字、null 也都是合法 JSON，照发
  assert_eq(
    @config.Config::default().with_data_from_json([1, 2]).serialize_body().bytes,
    Some(b"[1,2]"),
  )
  assert_eq(
    @config.Config::default().with_data_from_json(123).serialize_body().bytes,
    Some(b"123"),
  )
  assert_eq(
    @config.Config::default().with_data_from_json(Json::null()).serialize_body().bytes,
    Some(b"null"),
  )
}

///|
/// urlencoded：键值对编码成 `a=1&b=2` 并补 `application/x-www-form-urlencoded`。
///
/// 编码规则直接复用 query 那一套（axios 的 `toFormData` 默认选项），所以这里断言的
/// 全是 `url_test.mbt` 已经钉过的形状：数组/嵌套走括号、`null` 跳过、空格写成 `+`、
/// 非 ASCII 按 UTF-8 字节转义。
test "urlencoded body reuses the query serializer" {
  let flat = @config.Config::default()
    .with_data_from_urlencoded({ "user": "alice", "password": "s3cret" })
    .serialize_body()
  assert_eq(flat.bytes, Some(b"user=alice&password=s3cret"))
  assert_eq(flat.content_type, Some("application/x-www-form-urlencoded"))
  // 数组与嵌套对象：方括号会被百分号编码（axios 的真实输出）
  assert_eq(
    @config.Config::default()
    .with_data_from_urlencoded({ "tags": ["a", "b"] })
    .serialize_body().bytes,
    Some(b"tags%5B%5D=a&tags%5B%5D=b"),
  )
  assert_eq(
    @config.Config::default()
    .with_data_from_urlencoded({ "filter": { "status": 1 } })
    .serialize_body().bytes,
    Some(b"filter%5Bstatus%5D=1"),
  )
  // 空格写成 +、中文按 UTF-8 字节转义、null 键跳过
  assert_eq(
    @config.Config::default()
    .with_data_from_urlencoded({ "q": "中文 空格", "skip": Json::null() })
    .serialize_body().bytes,
    Some(@utf8.encode("q=%E4%B8%AD%E6%96%87+%E7%A9%BA%E6%A0%BC")),
  )
  // 顶层不是对象 → 空表单（与 axios 的 paramsSerializer 一致），类型照补
  let scalar = @config.Config::default()
    .with_data_from_urlencoded(123)
    .serialize_body()
  assert_eq(scalar.bytes, Some(b""))
  assert_eq(scalar.content_type, Some("application/x-www-form-urlencoded"))
}

///|
/// 表单：`multipart/form-data` + 自动 boundary，文本项与文件项按追加顺序成段。
///
/// 逐字节钉住布局：`--B\r\n` 起段、`Content-Disposition` 带 `name`，
/// 文件段多一条 `filename` 与 per-part `Content-Type`，文本段没有类型行，
/// 最后以 `--B--\r\n` 收尾。
test "form body is multipart with a matching boundary" {
  let form = @config.FormData::new()
    .append_text("title", "假期")
    .append_file("avatar", "a.png", b"\x89PNG", content_type="image/png")
  let serialized = @config.Config::default()
    .with_data_from_form(form)
    .serialize_body()
  let content_type = serialized.content_type.unwrap()
  // 头里声明的是标准的多媒体类型 + 自动生成的 boundary
  assert_true(
    content_type.contains("multipart/form-data; boundary=----moonhttp-"),
  )
  let boundary = boundary_of(content_type)
  let expected = @utf8.encode(
      "--" +
      boundary +
      "\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\n" +
      "假期\r\n--" +
      boundary +
      "\r\nContent-Disposition: form-data; name=\"avatar\"; filename=\"a.png\"\r\n" +
      "Content-Type: image/png\r\n\r\n",
    ) +
    b"\x89PNG" +
    @utf8.encode("\r\n--" + boundary + "--\r\n")
  assert_eq(serialized.bytes, Some(expected))
}

///|
/// 空表单照样发一个结束分隔符：它仍然是一份合法的空表单
/// （浏览器发 `new FormData()` 就是这个形状），而不是「没有 body」。
test "empty form still sends the closing boundary" {
  let serialized = @config.Config::default()
    .with_data_from_form(@config.FormData::new())
    .serialize_body()
  let boundary = boundary_of(serialized.content_type.unwrap())
  assert_eq(serialized.bytes, Some(@utf8.encode("--" + boundary + "--\r\n")))
}

///|
/// `name` 与 `filename` 里的引号和换行按 WHATWG 规则转义，
/// 否则带引号的字段名会让服务端把参数解析错位、甚至注入额外的头。
test "field names and filenames are escaped in content disposition" {
  let form = @config.FormData::new()
    .append_text("a\"b\r\nX-Injected: 1", "v")
    .append_file("f", "we\"ird\r\nname.txt", b"x")
  let serialized = @config.Config::default()
    .with_data_from_form(form)
    .serialize_body()
  let body = @utf8.decode_lossy(serialized.bytes.unwrap())
  assert_true(body.contains("name=\"a%22b%0D%0AX-Injected: 1\""))
  assert_true(body.contains("filename=\"we%22ird%0D%0Aname.txt\""))
  // 注入的换行没有真的变成一条新头
  assert_false(body.contains("\r\nX-Injected: 1\r\n"))
  // 没给内容类型的文件按 application/octet-stream 发
  assert_true(body.contains("Content-Type: application/octet-stream"))
}

///|
/// 表单是值语义：`append_*` 返回新实例，模板不受影响；同名可以出现多次。
test "form data is immutable and keeps append order" {
  let template = @config.FormData::new().append_text("a", "1")
  let extended = template
    .append_text("a", "2")
    .append_file("f", "x.bin", b"\x00\x01")
  assert_eq(template.length(), 1)
  assert_true(!extended.is_empty())
  assert_eq(extended.length(), 3)
  // 顺序就是追加顺序，同名字段不被合并
  let entries = extended.entries()
  assert_eq(entries[0].0, "a")
  assert_eq(entries[1].0, "a")
  assert_eq(entries[2].0, "f")
  // entries 是副本：改它不影响表单本身
  ignore(entries.pop())
  assert_eq(extended.length(), 3)
  assert_eq(@config.FormData::new().to_string(), "FormData { }")
}

///|
/// 表单的字符串渲染：文本给原文，文件只给文件名、类型与字节数（不打印正文）。
test "form data renders names and file sizes" {
  let form = @config.FormData::new()
    .append_text("a", "1")
    .append_file("f", "x.bin", b"\x00\x01")
  assert_eq(
    form.to_string(),
    "FormData { a: 1, f: @x.bin (application/octet-stream, 2 bytes) }",
  )
}

///|
/// `Config::to_string` 按 body 形态渲染 `data` 一栏：原样文本给原文、
/// JSON 与 urlencoded 给真正会发出去的文本、表单交给 `FormData`。
test "config renders every body kind" {
  assert_eq(
    @config.Config::default().with_data_from_str("raw").to_string(),
    "Config { data: raw }",
  )
  assert_true(
    @config.Config::default()
    .with_data_from_json({ "a": 1 })
    .to_string()
    .contains("data: {"),
  )
  assert_eq(
    @config.Config::default()
    .with_data_from_urlencoded({ "a": 1, "b": "x y" })
    .to_string(),
    "Config { data: a=1&b=x+y }",
  )
  let form = @config.FormData::new().append_text("a", "1")
  assert_true(
    @config.Config::default()
    .with_data_from_form(form)
    .to_string()
    .contains("data: FormData { a: 1 }"),
  )
}
