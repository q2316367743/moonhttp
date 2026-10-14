// 连接池：以「响应体消费完才回池、取消 = 毒化」为前提的空闲连接缓存
// （docs/17 口径 4、分期表第 2 期；设计与契约映射见 docs/21）。
//
// 运行时模型决定了池不需要锁：moonbitlang/async 是单线程协作式调度，
// acquire / release 全程没有 await 点，协程不会在池操作半途被打断，
// 普通可变结构就是安全的。本期「每 host 上限」只约束**空闲**数量
// （用户拍板）：桶满了直接关，不排队、不限并发；「并发上限 + 等待队列」
// 是后续增强（需要 Semaphore）。

///|
/// 一条空闲连接：连接本体 + 入池时刻（惰性过期的判据）。
priv struct PooledConn {
  conn : Connection
  idle_since : Int64
}

///|
/// 连接池本体。`buckets` 的键是「一条连接到底服务谁」的完整坐标
/// （scheme / tls / host / port / proxy，见 `pool_key`），值是 LIFO 栈——
/// 刚还回去的连接最可能还热着（TLS 会话、TCP 拥塞窗口都是热的）。
priv struct ConnectionPool {
  buckets : Map[String, Array[PooledConn]]
  /// 每 host 的空闲连接上限；0 = 禁池（release 一律关闭，行为退回 phase 1）
  max_idle_per_host : Int32
  /// 空闲连接的保活时长（毫秒）；<= 0 = 不过期，对端关闭由取用失败兜底
  idle_timeout_ms : Int32
}

///|
/// 池的缺省参数：每 host 最多 4 条空闲连接（urllib3 的 pool_maxsize 同款），
/// 空闲保活 30 秒（Go 的 IdleConnTimeout 是 90s，取短一点对服务端友好，
/// 也少踩「服务端早就关了」的重试路径）。
const DEFAULT_MAX_IDLE_PER_HOST : Int32 = 4

///|
const DEFAULT_IDLE_TIMEOUT_MS : Int32 = 30_000

///|
fn ConnectionPool::new(
  max_idle_per_host : Int32,
  idle_timeout_ms : Int32,
) -> ConnectionPool {
  { buckets: {}, max_idle_per_host, idle_timeout_ms, }
}

///|
/// 池是否被禁用（max_idle_per_host = 0）：release 一律关闭连接，
/// 请求头也回到 phase 1 的 `Connection: close` 口径。
fn ConnectionPool::disabled(self : ConnectionPool) -> Bool {
  self.max_idle_per_host <= 0
}

///|
/// 取一条空闲连接：LIFO 弹出，路上顺手清掉过期的。
/// 返回 `None` 表示池里没有可用的（该拨号了）。
fn ConnectionPool::acquire(self : ConnectionPool, key : String) -> Connection? {
  let bucket = match self.buckets.get(key) {
    Some(bucket) => bucket
    None => return None
  }
  while bucket.length() > 0 {
    let pooled = bucket.pop().unwrap()
    if self.expired(pooled.idle_since) {
      // 惰性过期：不在后台起定时器，取用时才发现、顺手清掉
      pooled.conn.close()
    } else {
      return Some(pooled.conn)
    }
  }
  // 空桶删掉，键空间（host 数量）才不会只增不减
  self.buckets.remove(key)
  None
}

///|
/// 还连接入池。池禁用 / 桶满时直接关——上限只约束空闲数量，
/// 不排队；多出来的连接当场回收。
fn ConnectionPool::release(
  self : ConnectionPool,
  key : String,
  conn : Connection,
) -> Unit {
  if self.disabled() {
    conn.close()
    return
  }
  let bucket = match self.buckets.get(key) {
    Some(bucket) => bucket
    None => {
      let fresh : Array[PooledConn] = []
      self.buckets.set(key, fresh)
      fresh
    }
  }
  if bucket.length() >= self.max_idle_per_host {
    conn.close()
    return
  }
  bucket.push({ conn, idle_since: @async.now(), })
}

///|
fn ConnectionPool::expired(self : ConnectionPool, idle_since : Int64) -> Bool {
  if self.idle_timeout_ms <= 0 {
    return false
  }
  @async.now() - idle_since > self.idle_timeout_ms.to_int64()
}

///|
/// 池的桶键：「一条连接到底服务谁」的完整坐标。同 host 不同端口的连接
/// 没有互换性；CONNECT 隧道按「目标 + 代理 + 凭据」建立，代理匿名与否、
/// 凭据换了一组，隧道都不能混用。tls 位显式入键（scheme 与它本应一一对应，
/// 双保险）。
///
/// **键里含代理凭据：只许当 Map 键用，绝不能打印或进日志。**
fn pool_key(target : Target, proxy : @transport.ProxyEndpoint?) -> String {
  let base = "\{target.scheme}|tls=\{target.use_tls}|\{target.host}:\{target.port}"
  match proxy {
    None => "\{base}|direct"
    Some(endpoint) => {
      let auth = match endpoint.authorization {
        Some(value) => value
        None => ""
      }
      "\{base}|proxy=\{endpoint.url}|\{auth}"
    }
  }
}
