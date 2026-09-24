// `params_serializer` 的构建器（字段本身在 config.mbt 的结构体里，
// 合并逻辑在 merge.mbt，渲染在 render.mbt）。
//
// 为什么单独一个文件而不是留在 config.mbt：那个文件已经贴着 RL-04 的 300 行上限，
// 而构建器是这块唯一搬得动的部分（字段必须在结构体里）。与 `proxy.mbt` 同一思路
// ——文件按功能分，而不是按「所有构建器放一起」分。

///|
/// 自定义 query 序列化器，对应 axios 的 `paramsSerializer`（函数形式）。
///
/// 传入的函数整体替换内置的序列化规则，返回值就是 query 本体。适合内置约定不合用的
/// 后端——例如列表要写成重复平键 `tags=a&tags=b`，而不是 axios 那套
/// `tags%5B%5D=a`：
///
/// ```moonbit nocheck
/// Config::new("/search")
///   .with_params({ "tags": ["a", "b"] })
///   .with_params_serializer(fn(_params) { "tags=a&tags=b" })
/// ```
///
/// 只管 URL 的 query，不管请求体（理由见 `Config::params_serializer` 的字段说明）；
/// 合并时请求级整体替换实例默认值。
pub fn Config::with_params_serializer(
  self : Config,
  params_serializer : (Json) -> String,
) -> Config {
  { ..self, params_serializer: Some(params_serializer), }
}
