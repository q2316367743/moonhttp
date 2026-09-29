// tchar / token 校验的规则测试：自定义方法的「存原样发原样」全靠这道闸。

///|
/// 标准 token 形状全部放行：字母数字与全部 16 个特殊 tchar。
test "valid tokens are accepted" {
  assert_true(@httpproto.is_token("GET"))
  assert_true(@httpproto.is_token("PROPFIND"))
  // 小写也是合法 token：HTTP 方法区分大小写，惯例大写由调用方保证
  assert_true(@httpproto.is_token("report"))
  assert_true(@httpproto.is_token("X-Custom-Method_2.0"))
  assert_true(@httpproto.is_token("!#$%&'*+-.^_`|~"))
  assert_true(@httpproto.is_token("A1"))
}

///|
/// 非法形状全部拒绝：空串、含空格（「冒号前有空白」同源）、分隔符、
/// 控制字符、非 ASCII。
test "invalid tokens are rejected" {
  assert_false(@httpproto.is_token(""))
  assert_false(@httpproto.is_token("GET ")) // 尾随空格
  assert_false(@httpproto.is_token("G ET")) // 中间空格
  assert_false(@httpproto.is_token("GET\t"))
  assert_false(@httpproto.is_token("GE(T)")) // 括号是分隔符不是 tchar
  assert_false(@httpproto.is_token("GET/1")) // 斜杠是分隔符
  assert_false(@httpproto.is_token("G:T")) // 冒号是分隔符
  assert_false(@httpproto.is_token("中文")) // 非 ASCII 不是 token 字符
}
