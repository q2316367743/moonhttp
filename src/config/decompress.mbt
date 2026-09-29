// 响应解压开关（对应 axios 的 `decompress`）。
//
// 为什么单独一个文件而不是留在 config.mbt：那里已经贴着 RL-04 的 300 行上限，
// 而字段必须留在结构体里、搬不动（与 `progress.mbt` / `serializer.mbt` 同一思路，
// 文件按功能分）。
//
// 谁声明 `Accept-Encoding`、谁解压、响应头怎么变，见 `docs/15-response-compression.md`。

///|
/// 关掉响应体的自动解压，对应 axios 的 `decompress: false`。
///
/// 默认（`true`）时，响应体带 `Content-Encoding: gzip` 会被解压成实体字节；
/// 关掉之后交出去的字节就是线上原样的字节，`Content-Encoding` / `Content-Length`
/// 也保持原样——「头里还有 `Content-Encoding`」与「字节仍是编码后的」始终一致。
///
/// 想自己解压（例如换用别的解压实现）、或要把压缩字节原样转存时用它。
///
/// ```moonbit nocheck
/// let config = Config::new("/package.tgz").with_decompress(false)
/// ```
pub fn Config::with_decompress(self : Config, decompress : Bool) -> Config {
  { ..self, decompress: Some(decompress), }
}
