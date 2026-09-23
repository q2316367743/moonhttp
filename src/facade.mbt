///|
/// 门面：把子包里对使用者有意义的类型从根包再导出一份。
///
/// 这样开发者只 import 一个 `@easy-http-client` 就能拿到全部公开类型，
/// 不必记住每个类型归属哪个子包。子包结构本身仍然保留，
/// 需要精细控制的使用者（例如自己实现 `Transport`）可以直接依赖对应子包。
///
/// 约定：凡是出现在公开签名里的类型，都在定义它的包里再导出一次，
/// 因此各层之间不会出现「要用这个 API 却不知道类型该从哪 import」的情况。
pub using @config {type Config, type Method, type Auth, type ResponseType}

///|
pub using @headers {type Headers}

///|
/// 传输层抽象也一并再导出：自定义传输实现是公开的扩展点。
pub using @transport {trait Transport}
