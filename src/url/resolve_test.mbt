///|
/// 带 scheme 的 Location 原样采用（scheme 大小写不敏感地判为绝对地址）。
test "resolve_url keeps absolute locations" {
  assert_eq(
    @url.resolve_url("https://api.example.com/users", "https://other.com/x"),
    Some("https://other.com/x"),
  )
  assert_eq(
    @url.resolve_url("https://api.example.com/users", "HTTPS://Other.com/X"),
    Some("HTTPS://Other.com/X"),
  )
  // 不支持的 scheme 也照样解析出来：能不能发出去由传输层判定
  assert_eq(
    @url.resolve_url(
      "https://api.example.com/users", "ftp://files.example.com/a",
    ),
    Some("ftp://files.example.com/a"),
  )
}

///|
/// 协议相对地址借基地址的 scheme。
test "resolve_url borrows scheme for protocol relative locations" {
  assert_eq(
    @url.resolve_url(
      "https://api.example.com/users", "//cdn.example.com/lib.js",
    ),
    Some("https://cdn.example.com/lib.js"),
  )
  assert_eq(
    @url.resolve_url("http://api.example.com/users", "//cdn.example.com:8080/x"),
    Some("http://cdn.example.com:8080/x"),
  )
}

///|
/// 以 `/` 开头是根相对路径：authority 不变，基地址的 query 不继承。
test "resolve_url replaces path for root relative locations" {
  assert_eq(
    @url.resolve_url("https://api.example.com/users?page=1", "/v2/users"),
    Some("https://api.example.com/v2/users"),
  )
  assert_eq(
    @url.resolve_url("https://api.example.com/api/v1/users", "/v2/users"),
    Some("https://api.example.com/v2/users"),
  )
}

///|
/// 相对路径与基地址所在目录合并（RFC 3986 §5.3 的 merge），
/// 基地址的最后一个路径段整体被替换掉。
test "resolve_url merges relative paths with the base directory" {
  assert_eq(
    @url.resolve_url("https://api.example.com/api/v1/users", "edit"),
    Some("https://api.example.com/api/v1/edit"),
  )
  // 基地址没有路径时按 `/` 合并
  assert_eq(
    @url.resolve_url("https://api.example.com", "users"),
    Some("https://api.example.com/users"),
  )
  assert_eq(
    @url.resolve_url("https://api.example.com?page=1", "users"),
    Some("https://api.example.com/users"),
  )
}

///|
/// 点段按 RFC 3986 §5.2.4 归并：`.` 丢掉、`..` 回退一段、根上的 `..` 不退。
test "resolve_url removes dot segments" {
  assert_eq(
    @url.resolve_url("https://api.example.com/dir/page", "../x"),
    Some("https://api.example.com/x"),
  )
  assert_eq(
    @url.resolve_url("https://api.example.com/dir/page", "sub/../x"),
    Some("https://api.example.com/dir/x"),
  )
  assert_eq(
    @url.resolve_url("https://api.example.com", "/../a"),
    Some("https://api.example.com/a"),
  )
  assert_eq(
    @url.resolve_url("https://api.example.com", "/a/b/../c"),
    Some("https://api.example.com/a/c"),
  )
  assert_eq(
    @url.resolve_url("https://api.example.com", "/a/./b/"),
    Some("https://api.example.com/a/b/"),
  )
  assert_eq(
    @url.resolve_url("https://api.example.com", "/a/.."),
    Some("https://api.example.com/"),
  )
}

///|
/// 相对引用里的 query 不会被当成路径的一部分：它要参与「点段归并」之外的
/// 全部解析，且基地址的 query 不继承。
test "resolve_url keeps the reference query out of the path" {
  assert_eq(
    @url.resolve_url(
      "https://api.example.com/api/v1/users?page=1", "../v2/users?page=2",
    ),
    Some("https://api.example.com/api/v2/users?page=2"),
  )
  assert_eq(
    @url.resolve_url("https://api.example.com/dir/page", "a/..?x=1"),
    Some("https://api.example.com/dir/?x=1"),
  )
  assert_eq(
    @url.resolve_url("https://api.example.com/a/b?old=1", "c"),
    Some("https://api.example.com/a/c"),
  )
}

///|
/// 只换 query（`?` 开头）与只换 fragment（`#` 开头）两种引用。
/// fragment 不随请求发出，所以只带 fragment 的重定向等于重新请求同一个地址。
test "resolve_url handles query and fragment only references" {
  assert_eq(
    @url.resolve_url("https://api.example.com/users?page=1", "?page=2"),
    Some("https://api.example.com/users?page=2"),
  )
  assert_eq(
    @url.resolve_url("https://api.example.com/users?page=1", "#top"),
    Some("https://api.example.com/users?page=1"),
  )
  assert_eq(
    @url.resolve_url("https://api.example.com/users", "#top"),
    Some("https://api.example.com/users"),
  )
}

///|
/// 结果里不含 fragment：`build_url` 只会在追加 query 时顺手丢它，
/// 重定向的下一跳不追加 query，留着就会把 `#frag` 当路径发出去。
test "resolve_url strips fragments" {
  assert_eq(
    @url.resolve_url("https://api.example.com/users", "/v2/users#section"),
    Some("https://api.example.com/v2/users"),
  )
  assert_eq(
    @url.resolve_url("https://api.example.com/a#seed", "b#section"),
    Some("https://api.example.com/b"),
  )
}

///|
/// 空引用落到基地址自身（含 query）。
test "resolve_url keeps the base for an empty reference" {
  assert_eq(
    @url.resolve_url("https://api.example.com/users?page=1", ""),
    Some("https://api.example.com/users?page=1"),
  )
  // 头值两边的空白不算地址的一部分
  assert_eq(
    @url.resolve_url("https://api.example.com/users", "  /v2  "),
    Some("https://api.example.com/v2"),
  )
}

///|
/// 基地址不是绝对地址时返回 None——相对解析需要 scheme 与 authority。
test "resolve_url requires an absolute base" {
  assert_eq(@url.resolve_url("/users", "/v2"), None)
  assert_eq(@url.resolve_url("api.example.com/users", "/v2"), None)
  assert_eq(@url.resolve_url("1http://api.example.com/users", "/v2"), None)
}

///|
/// scheme 只有 `scheme://` 这一种形式算数，与 `is_absolute_url` 的口径一致。
test "url_scheme only recognises scheme with authority" {
  assert_eq(@url.url_scheme("https://api.example.com/users"), Some("https"))
  assert_eq(@url.url_scheme("HTTPS://api.example.com"), Some("https"))
  assert_eq(@url.url_scheme("http://127.0.0.1:8080/x"), Some("http"))
  assert_eq(@url.url_scheme("/users"), None)
  assert_eq(@url.url_scheme("localhost:8080/users"), None)
  assert_eq(@url.url_scheme("mailto:a@b.com"), None)
}

///|
/// authority 归一化：去 userinfo、主机名小写、默认端口去掉。
test "url_authority normalises hosts" {
  assert_eq(
    @url.url_authority("https://Example.COM:443/a"),
    Some("example.com"),
  )
  assert_eq(@url.url_authority("http://Example.com:80/a"), Some("example.com"))
  // 非默认端口保留
  assert_eq(
    @url.url_authority("http://Example.com:8080/a"),
    Some("example.com:8080"),
  )
  assert_eq(@url.url_authority("https://a.com:80/a"), Some("a.com:80"))
  // userinfo 不参与比较
  assert_eq(
    @url.url_authority("https://alice:pw@Example.com/x"),
    Some("example.com"),
  )
  assert_eq(@url.url_authority("/users"), None)
}

///|
/// IPv6 字面量里的冒号不是端口分隔符。
test "url_authority handles IPv6 literals" {
  assert_eq(@url.url_authority("http://[::1]:80/x"), Some("[::1]"))
  assert_eq(@url.url_authority("http://[::1]:8080/x"), Some("[::1]:8080"))
  assert_eq(
    @url.url_authority("https://[2001:db8::1]/x"),
    Some("[2001:db8::1]"),
  )
}
