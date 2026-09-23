// 根包的白盒测试：覆盖只能从包内部触达的分支。

///|
/// `validate_status` 为 `None` 时一律放行。
///
/// 这条分支只有白盒测试能覆盖：公开入口（`Client::new` / `create`）都会先把
/// 内置默认值合并进来，而内置默认值一定带着 2xx 规则，所以走不到 `None`。
/// 之所以保留它，是因为 `Config` 的字段语义就是「`None` = 未提供」，
/// 校验函数不该依赖「默认值一定设了校验规则」这个外部前提。
test "validate_response lets everything through without a rule" {
  let response : Response = {
    data: Json::null(),
    status: 500,
    status_text: "Internal Server Error",
    headers: Headers::new(),
    config: Config::default(),
    raw: b"",
  }
  // 不抛错即为通过
  validate_response(response)
}
