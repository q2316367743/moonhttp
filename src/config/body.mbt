// 请求体的四种形态与它们的序列化。
//
// `Config.data` 是**私有字段**（只有本包能读写），外部只能经四个 `with_data_from_*`
// 构建器设置；序列化由 `Config::serialize_body` 在本包完成——字段私有之后，
// 只有本包能 match `Body`，而 multipart 编码（form.mbt）也属于「请求体的含义」，
// 与类型定义放在一起，改一处就够。

///|
/// 请求体的四种形态：数据本身 + 「怎么序列化」的标签。
///
/// 为什么不直接存 `Json?`：老实现拿 `Json::String` 当「原样文本」的标记，
/// 于是 `with_data_from_json("hi")`（要发带引号的 `"hi"` 并补 JSON 头）与
/// `with_data_from_str("hi")`（原样发 `hi`、不推断类型）会在同一个 Json 值上撞车。
/// 把标签与数据分开，四个构建器才都能表达清楚自己的意思。
priv enum Body {
  /// 原样文本：UTF-8 字节直接发送，不推断 Content-Type
  Raw(String)
  /// JSON 值：`stringify()` 后发送，补 `application/json`
  Json(Json)
  /// 表单：编码成 `multipart/form-data`，补带 boundary 的 Content-Type
  Form(FormData)
  /// URL 编码表单：`a=1&b=2`，补 `application/x-www-form-urlencoded`
  UrlEncoded(Json)
}

///|
/// 请求体序列化的结果：待发送字节 + 建议补上的 `Content-Type`。
///
/// 这是 `Config` 的请求体对外的唯一读法（字段本身是私有的）。
pub(all) struct SerializedBody {
  /// 待发送字节；`None` 表示不带 body
  bytes : Bytes?
  /// 建议补上的 `Content-Type`；`None` 表示不推断。
  ///
  /// 落到请求上时一律走 `Headers::set_if_absent`：用户显式设置的同名头永远优先。
  content_type : String?
}

///|
/// 以原样文本为请求体：不做任何处理，按 UTF-8 编码后发送，**也不推断 Content-Type**。
///
/// 适合纯文本，以及调用方自己序列化好的载体——例如手拼的 urlencoded 表单：
///
/// ```moonbit nocheck
/// @moonhttp.Config::new("/login")
///   .with_data_from_str("user=alice&password=s3cret")
///   .with_header("Content-Type", "application/x-www-form-urlencoded")
/// ```
///
/// 想要「发出去的是合法 JSON」请用 `with_data_from_json`：它会把值序列化并补头。
pub fn Config::with_data_from_str(self : Config, body : String) -> Config {
  { ..self, data: Some(Body::Raw(body)), }
}

///|
/// 以 JSON 为请求体：自动 `stringify()` 成 JSON 文本，并补 `Content-Type: application/json`。
///
/// 注意 `with_data_from_json(Json::String("hi"))` 发出去的是**带引号的** `"hi"`——
/// 它是 JSON 字符串字面量，与 `with_data_from_str("hi")` 发出的裸 `hi` 不是一回事，
/// 后者也不会补 JSON 头。
pub fn Config::with_data_from_json(self : Config, body : Json) -> Config {
  { ..self, data: Some(Body::Json(body)), }
}

///|
/// 以表单为请求体：编码成 `multipart/form-data`（文本字段与文件都走这条），
/// 并补 `Content-Type: multipart/form-data; boundary=...`，boundary 每次序列化现生成。
///
/// 文件以「字节 + 文件名」传入（见 `FormData::append_file`）：库不读盘，
/// 从内存造字节或自己读文件都由调用方决定。
pub fn Config::with_data_from_form(self : Config, form : FormData) -> Config {
  { ..self, data: Some(Body::Form(form)), }
}

///|
/// 以 URL 编码表单（`application/x-www-form-urlencoded`）为请求体：
/// 键值对编码成 `a=1&b=2` 后发送，并补 `Content-Type: application/x-www-form-urlencoded`。
///
/// 与 `params` 用的是**同一套序列化规则**（axios 的 `toFormData` 默认选项），
/// 所以同一份 `Json` 放 query 还是放 body 只差一个方法名：
/// `{"a": 1}` → `a=1`，数组与嵌套对象按 `tags%5B%5D=a&tags%5B%5D=b`、
/// `filter%5Bstatus%5D=1` 展开（方括号会被百分号编码，这是 axios 的真实输出），
/// 值为 `null` 的键一律跳过，空格写成 `+`。
///
/// 顶层必须是对象：传数组或标量等于一份空表单（与 axios 的 `paramsSerializer` 一致）。
/// 后端要的是别的约定（例如列表用重复平键 `tags=a&tags=b`）时，
/// 用 `with_data_from_str` 自己拼 + 自己设 `Content-Type`。
///
/// 文件不行：urlencoded 里没有承载二进制的位置，带文件请用 `with_data_from_form`。
pub fn Config::with_data_from_urlencoded(self : Config, body : Json) -> Config {
  { ..self, data: Some(Body::UrlEncoded(body)), }
}

///|
/// 把请求体序列化成待发送字节与建议的 `Content-Type`；没有 body 时两者都是 `None`。
///
/// 为什么序列化在 config 包而不是拼请求的地方：`data` 私有，只有本包能 match `Body`；
/// 而「body 怎么变成字节」本来就是请求体类型自己的事（与 `url/` 包负责百分号编码同理）。
/// 拼请求的那一层只负责把这里给出的 `content_type` 用 `set_if_absent` 落到头上。
pub fn Config::serialize_body(self : Config) -> SerializedBody {
  match self.data {
    None => { bytes: None, content_type: None, }
    // 原样文本：不推断类型，调用方可能就是想发纯文本或自己序列化好的载体。
    Some(Body::Raw(text)) =>
      { bytes: Some(@utf8.encode(text)), content_type: None, }
    Some(Body::Json(json)) =>
      {
        bytes: Some(@utf8.encode(json.stringify())),
        content_type: Some("application/json"),
      }
    Some(Body::Form(form)) => {
      // boundary 每次序列化现生成：同一个 Config 发多次请求不会复用同一个分隔符。
      let boundary = random_boundary()
      {
        bytes: Some(multipart_body(form, boundary)),
        content_type: Some("multipart/form-data; boundary=" + boundary),
      }
    }
    Some(Body::UrlEncoded(fields)) =>
      {
        bytes: Some(@utf8.encode(urlencoded_text(fields))),
        content_type: Some("application/x-www-form-urlencoded"),
      }
  }
}

///|
/// urlencoded 请求体的文本形式（不含前导 `?`）。
///
/// 单独抽一层是为了让**序列化与渲染共用同一段逻辑**：`Config::to_string` 打印的就是
/// 真正会发出去的文本。编码规则本身直接复用 `url` 包里那一份——
/// 请求体的 urlencoded 与 URL 的 query 在 axios 里本来就是同一个序列化器
/// （`toFormData` / `paramsSerializer` 的默认选项），不重复实现两套百分号编码。
fn urlencoded_text(fields : Json) -> String {
  @url.serialize_params(fields)
}
