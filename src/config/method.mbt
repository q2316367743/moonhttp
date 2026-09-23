///|
/// HTTP 请求方法。
///
/// 这里独立定义一份枚举，而不是直接复用 `moonbitlang/async/http` 的 `RequestMethod`，
/// 是为了让 config / headers / merge / url 这几个包保持纯逻辑、不依赖 async 运行时；
/// 两者之间的转换被隔离在 transport 包里。
///
/// 派生 `Hash` 是必须的：`Config.method_headers` 用 `Map[Method, Headers]` 存
/// 「按方法分层的默认头」，而 Map 的 key 需要 `Hash + Eq`。
pub(all) enum Method {
  Get
  Head
  Post
  Put
  Delete
  Connect
  Options
  Trace
  Patch
} derive(Eq, Hash, Debug)

///|
pub extend Method with Eq::{equal, not_equal}

///|
pub extend Method with Hash::{hash, hash_combine}

///|
pub extend Method with @debug.Debug::{to_repr}

///|
/// 请求行里使用的大写方法名，例如 `GET`。用于拼出可读的请求行与日志。
pub fn Method::to_string(self : Method) -> String {
  match self {
    Get => "GET"
    Head => "HEAD"
    Post => "POST"
    Put => "PUT"
    Delete => "DELETE"
    Connect => "CONNECT"
    Options => "OPTIONS"
    Trace => "TRACE"
    Patch => "PATCH"
  }
}

///|
/// 解析方法名，大小写不敏感；无法识别时返回 `None`。
///
/// 不在这里抛错：调用方（传输层或用户代码）才知道该报什么错，
/// 保持这个纯函数只有「找到/没找到」两种结果。
pub fn Method::parse(name : StringView) -> Method? {
  for meth in [Get, Head, Post, Put, Delete, Connect, Options, Trace, Patch] {
    // compare_ignore_ascii_case 比先大小写折叠再比较更直接，也少一次分配。
    if name.compare_ignore_ascii_case(meth.to_string()) == 0 {
      return Some(meth)
    }
  }
  None
}
