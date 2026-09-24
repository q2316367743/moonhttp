// 表单请求体（对应 axios 的 `FormData`）：值类型 + `multipart/form-data` 编码。
//
// 一律编码成 multipart——纯文本字段也走这条，与浏览器的 `FormData` 行为一致，
// 这样「有没有文件」不会让线上格式在两种形态之间切换。
// 文件按「字节 + 文件名」传入：本包不碰 IO，读盘由调用方自己决定。

///|
/// 一个文件字段：发给服务端的文件名、该部分的内容类型、内容字节。
pub(all) struct FormFile {
  /// 文件名（`Content-Disposition` 的 `filename`），只能是文件名本身，不要带路径
  filename : String
  /// 该部分的内容类型，缺省 `application/octet-stream`
  content_type : String
  /// 文件字节
  bytes : Bytes
}

///|
/// 表单字段的值：文本或文件。
pub(all) enum FormValue {
  Text(String)
  File(FormFile)
}

///|
/// 表单请求体：有序的「字段名 → 值」列表。
///
/// 同名可以出现多次（多个值、多个文件都会各自成为一项），顺序就是 `append_*` 的顺序，
/// 服务端通常按顺序取第一个同名项，所以「同名字段覆盖」这类语义不在这里做。
///
/// 与 `Headers` 一样是值语义：`append_*` 返回新实例，
/// 拿一份表单当模板派生出多份，互相之间不会被改坏。
pub struct FormData {
  priv parts : Array[(String, FormValue)]
}

///|
/// 空表单。
pub fn FormData::new() -> FormData {
  { parts: [], }
}

///|
/// 追加一个文本字段，返回新的表单。
pub fn FormData::append_text(
  self : FormData,
  name : StringView,
  value : String,
) -> FormData {
  self.append(name, FormValue::Text(value))
}

///|
/// 追加一个文件字段，返回新的表单。
///
/// `content_type` 省略时按 `application/octet-stream` 发送；
/// 传具体类型（如 `"image/png"`）会让服务端更容易识别。
///
/// ```moonbit nocheck
/// @moonhttp.FormData::new()
///   .append_text("title", "假期照片")
///   .append_file("avatar", "a.png", bytes, content_type="image/png")
/// ```
pub fn FormData::append_file(
  self : FormData,
  name : StringView,
  filename : StringView,
  bytes : Bytes,
  content_type? : String = "application/octet-stream",
) -> FormData {
  self.append(
    name,
    FormValue::File({ filename: filename.to_owned(), content_type, bytes, }),
  )
}

///|
/// 追加一项的公共实现，不导出：两个 `append_*` 只在「值怎么造」上不同。
fn FormData::append(
  self : FormData,
  name : StringView,
  value : FormValue,
) -> FormData {
  // 先 copy 再 push：parts 是共享的 Array，就地改会让别的表单跟着变。
  let parts = []
  for part in self.parts {
    parts.push(part)
  }
  parts.push((name.trim().to_owned(), value))
  { parts, }
}

///|
/// 字段项数（文本项与文件项都算一项）。
pub fn FormData::length(self : FormData) -> Int {
  self.parts.length()
}

///|
/// 是否一项都没有。
pub fn FormData::is_empty(self : FormData) -> Bool {
  self.parts.is_empty()
}

///|
/// 展开为「字段名, 值」数组，顺序为追加顺序。
///
/// 与 `Headers::entries` 同理，返回的是新数组：调用方拿到的副本怎么改都不会影响本表单。
pub fn FormData::entries(self : FormData) -> Array[(String, FormValue)] {
  let result = []
  for part in self.parts {
    result.push(part)
  }
  result
}

///|
/// 渲染为 `FormData { 名: 值, 名: @文件名 (内容类型, N bytes) }`，只用于日志与断言。
///
/// 文件不打印内容（只给字节数）：表单经常整个进日志，把文件正文打进去没有意义。
pub fn FormData::to_string(self : FormData) -> String {
  let buf = StringBuilder()
  let mut first = true
  for part in self.parts {
    let (name, value) = part
    first = push_field(buf, first, name, render_form_value(value))
  }
  render_braced("FormData", buf.to_string(), first)
}

///|
fn render_form_value(value : FormValue) -> String {
  match value {
    Text(text) => text
    File(file) =>
      "@" +
      file.filename +
      " (" +
      file.content_type +
      ", " +
      file.bytes.length().to_string() +
      " bytes)"
  }
}

///|
pub impl Show for FormData with fn to_string(self) {
  self.to_string()
}

///|
pub extend FormData with Show::{output}

///|
/// 手写 Debug 而不是 `derive(Debug)`：渲染内容与 `Show` 保持一致，避免出现两套格式。
pub impl @debug.Debug for FormData with fn to_repr(self) {
  @debug.Repr::string(self.to_string())
}

///|
pub extend FormData with @debug.Debug::{to_repr}

///|
/// 生成一个 multipart boundary：`----moonhttp-` 拼两个随机十进制数。
///
/// 只要足够不易与正文内容撞车即可（RFC 2046 要求 boundary 不出现在各部分内容里），
/// 不承担安全用途，所以直接用 core 的随机数。
fn random_boundary() -> String {
  let rand = @random.Rand::new()
  "----moonhttp-" + rand.uint64().to_string() + rand.uint64().to_string()
}

///|
/// 把一个表单编码成 `multipart/form-data` 正文（RFC 7578 / WHATWG 的字节布局）：
///
/// ```text
/// --B\r\n
/// Content-Disposition: form-data; name="title"\r\n
/// \r\n
/// 假期\r\n
/// --B\r\n
/// Content-Disposition: form-data; name="avatar"; filename="a.png"\r\n
/// Content-Type: image/png\r\n
/// \r\n
/// <文件字节>\r\n
/// --B--\r\n
/// ```
///
/// 两处刻意的选择：
/// - **文本项不带 per-part `Content-Type`**：浏览器的 `FormData` 与 node 的
///   `form-data` 都是这样，多补一个只会让某些服务端把它当成文件；
/// - **结尾的分隔符总是发**：空表单也发 `--B--\r\n`，与浏览器一致（那仍然是一个合法的空表单）。
fn multipart_body(form : FormData, boundary : String) -> Bytes {
  let buf = @buffer.Buffer::Buffer()
  for part in form.parts {
    let (name, value) = part
    buf.write_string_utf8("--")
    buf.write_string_utf8(boundary)
    buf.write_string_utf8("\r\nContent-Disposition: form-data; name=\"")
    buf.write_string_utf8(escape_disposition(name))
    buf.write_string_utf8("\"")
    match value {
      Text(text) => {
        buf.write_string_utf8("\r\n\r\n")
        buf.write_string_utf8(text)
      }
      File(file) => {
        buf.write_string_utf8("; filename=\"")
        buf.write_string_utf8(escape_disposition(file.filename))
        buf.write_string_utf8("\"\r\nContent-Type: ")
        buf.write_string_utf8(file.content_type)
        buf.write_string_utf8("\r\n\r\n")
        buf.write_bytes(file.bytes)
      }
    }
    buf.write_string_utf8("\r\n")
  }
  buf.write_string_utf8("--")
  buf.write_string_utf8(boundary)
  buf.write_string_utf8("--\r\n")
  buf.to_bytes()
}

///|
/// `Content-Disposition` 里 `name` / `filename` 的转义，按 WHATWG 的表单编码规则：
/// `"` → `%22`、CR → `%0D`、LF → `%0A`，其余字符（含非 ASCII）原样按 UTF-8 写。
///
/// 这是刻意与 axios 的差异：它依赖的 node `form-data` 对这两个值不做任何转义，
/// 字段名或文件名里带引号时服务端会把参数解析错位，甚至能被注入额外的参数。
fn escape_disposition(value : StringView) -> String {
  // 这里用 StringBuilder（UTF-16 语义），最后交给 Buffer 编码成 UTF-8；
  // 只有 `write_char`/`write_string` 可用，没有 Buffer 那套按编码分家的写入方法。
  let buf = StringBuilder(size_hint=value.length())
  for c in value {
    if c == '"' {
      buf.write_string("%22")
    } else if c == '\r' {
      buf.write_string("%0D")
    } else if c == '\n' {
      buf.write_string("%0A")
    } else {
      buf.write_char(c)
    }
  }
  buf.to_string()
}
