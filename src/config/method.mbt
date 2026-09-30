///|
/// HTTP 请求方法。
///
/// 这里独立定义一份枚举，而不是直接复用 `moonbitlang/async/http` 的 `RequestMethod`，
/// 是为了让 config / headers / merge / url 这几个包保持纯逻辑、不依赖 async 运行时；
/// 两者之间的转换被隔离在 transport 包里。
///
/// 派生 `Hash` 是必须的：`Config.method_headers` 用 `Map[Method, Headers]` 存
/// 「按方法分层的默认头」，而 Map 的 key 需要 `Hash + Eq`。
///
/// `Other` 承载自定义方法（WebDAV 的 `PROPFIND`、`REPORT` 等）：**存原样、发原样**
/// ——HTTP 方法 token 按 RFC 7230 区分大小写，大写惯例由调用方保证，
/// `to_string` 对它返回载荷本身。传输层原样发送（httpconn 为缺省实现），
/// 发送前校验 token 合法性，非法 token 在建连之前报 `Unsupported`。
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
  Other(String)
} derive(Eq, Hash, Debug)

///|
pub extend Method with Eq::{equal, not_equal}

///|
pub extend Method with Hash::{hash, hash_combine}

///|
pub extend Method with @debug.Debug::{to_repr}

///|
/// 请求行里使用的大写方法名，例如 `GET`。用于拼出可读的请求行与日志。
/// `Other` 返回载荷本身：方法 token 区分大小写，存的是什么就发什么。
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
    Other(name) => name
  }
}

///|
/// 解析方法名，大小写不敏感；无法识别时返回 `None`。
///
/// 不在这里抛错：调用方（传输层或用户代码）才知道该报什么错，
/// 保持这个纯函数只有「找到/没找到」两种结果。
///
/// 注意它**不**把未知名字解析成 `Other`：九个标准方法之外的名字一律 `None`。
/// `Other` 是调用方显式构造的「我要原样发这个 token」，而 `parse` 的语义是
/// 「这名字是不是标准方法」——把两者混起来，拼错的标准方法名（`GT` 想写 `GET`）
/// 就会被当成自定义方法静默发出去，错误从「一眼看出的笔误」变成「线上 405」。
pub fn Method::parse(name : StringView) -> Method? {
  for meth in [Get, Head, Post, Put, Delete, Connect, Options, Trace, Patch] {
    // compare_ignore_ascii_case 比先大小写折叠再比较更直接，也少一次分配。
    if name.compare_ignore_ascii_case(meth.to_string()) == 0 {
      return Some(meth)
    }
  }
  None
}
