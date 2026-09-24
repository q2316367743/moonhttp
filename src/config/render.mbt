// Config 的字符串渲染：Show / Debug 都走同一套紧凑格式，
// 只输出被显式提供的字段（None 只表示「未提供」，打印出来是噪音）。

///|
/// 把 `名字: 值` 追加进缓冲区，并返回更新后的「是否还是第一项」标记。
/// 供 `Config`/`Auth` 的字符串渲染复用，避免每处都写一遍分隔符逻辑。
fn push_field(
  buf : StringBuilder,
  first : Bool,
  name : String,
  value : String,
) -> Bool {
  if !first {
    buf.write_string(", ")
  }
  buf.write_string(name)
  buf.write_string(": ")
  buf.write_string(value)
  false
}

///|
/// 紧凑渲染，只打印被显式提供的字段。
///
/// `None` 表示「未提供」，把它打印出来只是噪音，也会让合并前后的对比失真。
/// `validate_status` 是函数，渲染成 `<fn>`。
pub fn Config::to_string(self : Config) -> String {
  let buf = StringBuilder()
  let mut first = true
  match self.url {
    Some(url) => first = push_field(buf, first, "url", url)
    None => ()
  }
  match self.http_method {
    // 标签沿用 axios 的字段名 method，便于和官方配置逐项对照。
    Some(meth) => first = push_field(buf, first, "method", meth.to_string())
    None => ()
  }
  match self.base_url {
    Some(base_url) => first = push_field(buf, first, "base_url", base_url)
    None => ()
  }
  match self.timeout {
    Some(timeout) =>
      first = push_field(buf, first, "timeout", timeout.to_string())
    None => ()
  }
  match self.max_redirects {
    Some(max_redirects) =>
      first = push_field(buf, first, "max_redirects", max_redirects.to_string())
    None => ()
  }
  match self.response_encoding {
    Some(encoding) =>
      first = push_field(buf, first, "response_encoding", encoding.to_string())
    None => ()
  }
  match self.params {
    Some(params) => first = push_field(buf, first, "params", params.stringify())
    None => ()
  }
  // 请求体按形态渲染：JSON 给序列化后的文本、urlencoded 给编码后的键值对
  // （两者都与真正发出去的一致），原样文本给原文，
  // 表单交给 FormData 自己渲染（文件只给字节数）。
  match self.data {
    Some(Body::Raw(text)) => first = push_field(buf, first, "data", text)
    Some(Body::Json(data)) =>
      first = push_field(buf, first, "data", data.stringify())
    Some(Body::Form(form)) =>
      first = push_field(buf, first, "data", form.to_string())
    Some(Body::UrlEncoded(fields)) =>
      first = push_field(buf, first, "data", urlencoded_text(fields))
    None => ()
  }
  match self.auth {
    Some(auth) => first = push_field(buf, first, "auth", auth.to_string())
    None => ()
  }
  match self.headers {
    Some(headers) =>
      first = push_field(buf, first, "headers", headers.to_string())
    None => ()
  }
  match self.common_headers {
    Some(headers) =>
      first = push_field(buf, first, "common_headers", headers.to_string())
    None => ()
  }
  match self.method_headers {
    Some(buckets) => {
      let bucket_buf = StringBuilder()
      let mut bucket_first = true
      for meth, headers in buckets {
        if !bucket_first {
          bucket_buf.write_string("; ")
        }
        bucket_first = false
        bucket_buf.write_string(meth.to_string())
        bucket_buf.write_string(" -> ")
        bucket_buf.write_string(headers.to_string())
      }
      first = push_field(buf, first, "method_headers", bucket_buf.to_string())
    }
    None => ()
  }
  match self.validate_status {
    Some(_) => first = push_field(buf, first, "validate_status", "<fn>")
    None => ()
  }
  match self.allow_absolute_urls {
    Some(allow) =>
      first = push_field(buf, first, "allow_absolute_urls", allow.to_string())
    None => ()
  }
  render_braced("Config", buf.to_string(), first)
}

///|
/// 拼出 `名字 { 字段, 字段 }`；一个字段都没有时退化成 `名字 { }`，
/// 避免出现 `名字 {  }` 这样的双空格。
fn render_braced(name : String, body : String, empty : Bool) -> String {
  if empty {
    name + " { }"
  } else {
    name + " { " + body + " }"
  }
}

///|
pub impl Show for Config with fn to_string(self) {
  self.to_string()
}

///|
pub extend Config with Show::{output}

///|
/// 手写 Debug 而不是 `derive(Debug)`：`validate_status` 是函数字段。
/// 渲染内容与 `Show` 保持一致，避免出现两套格式。
pub impl @debug.Debug for Config with fn to_repr(self) {
  @debug.Repr::string(self.to_string())
}

///|
pub extend Config with @debug.Debug::{to_repr}
