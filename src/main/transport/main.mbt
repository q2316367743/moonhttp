///|
/// 靶子地址：test/server.py 的默认端口（两处常量要一致，改一个得改另一个）。
let target_base : String = "http://127.0.0.1:18777"

///|
/// 示例：自研传输层（httpconn）的新语义，十段：
/// gzip 三态、大响应体、User-Agent、连接失败、超时、自定义方法、HTTP/1.0。
/// 每段的证据都取服务端视角——靶子把收到的请求头回吐在响应里。
/// 用 `moon run src/main/transport` 执行。本包只是示例，不随模块发布。
async fn main {
  let client = @moonhttp.create(
    @moonhttp.Config::default().with_base_url(target_base).with_timeout(10_000),
  )
  println(
    "靶子 = \{target_base}（bash test/run.sh 或 python3 test/server.py 启动）\n",
  )
  gzip_buffered(client)
  gzip_stream(client)
  gzip_off(client)
  gzip_user_declared(client)
  large_bodies(client)
  user_agent(client)
  connection_failures()
  timeout_case(client)
  custom_method(client)
  http10(client)
}

///|
/// 打一次请求并把结果收成 `Result`：示例要逐段打印，不想让某一段把整段带崩。
async fn request_or_error(
  client : @moonhttp.Client,
  config : @moonhttp.Config,
) -> Result[@moonhttp.Response, @moonhttp.HttpError] {
  Ok(client.request(config)) catch {
    error => Err(error)
  }
}

///|
/// 打一行「请求 → 抛出的分类与描述」；不抛就如实说（那反而是问题）。
async fn show_error(
  label : String,
  client : @moonhttp.Client,
  config : @moonhttp.Config,
) -> Unit {
  match request_or_error(client, config) {
    Ok(response) =>
      println(
        "\{label} → 竟然成功：\{response.status}（不符合预期）",
      )
    Err(error) => println("\{label} → \{error.code()}：\{error.message()}")
  }
}

///|
/// 从 `/echo` 回显的 headers 里取一个请求头（服务端视角的证据）。
fn echo_header(response : @moonhttp.Response, name : String) -> String {
  let echoed = response.json() catch { _ => return "<回显不是 JSON>" }
  match echoed {
    { "headers": Object(fields), .. } =>
      match fields.get(name) {
        Some(String(text)) => text
        Some(value) => value.stringify()
        None => "<没带>"
      }
    _ => "<回显不符合预期>"
  }
}

///|
/// 取字符串的前 `limit` 个字符（不足就整体返回）。
fn head_text(text : String, limit : Int) -> String {
  if text.length() <= limit {
    text
  } else {
    text[:limit].to_owned() + "…"
  }
}
