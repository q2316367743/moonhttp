// 请求取消（对应 axios 的 `cancelToken` / 原生 `AbortSignal`）。
//
// 为什么单独一个文件而不是留在 config.mbt：那里已经贴着 RL-04 的 300 行上限，
// 取消这块是能整体搬走的一部分（字段必须留在结构体里），与 `progress.mbt` /
// `proxy.mbt` 同一思路——文件按功能分。
//
// 这里只有**状态**，没有底层机制：token 记「取消没取消」以及一组回调，
// 真正打断一次请求的协程取消发生在 transport 包（那里才有 `@async`）。
// 这样取消的语义（谁能被取消、取消后读到什么）可以在 config 包里同步测试，
// 而 config 包始终不依赖 async 运行时。
//
// 契约细节（能打断什么、覆盖哪些入口、与 timeout / 重试的关系）见
// `docs/12-cancellation.md`。

///|
/// 取消状态。一次性的：从 `Pending` 走到 `Cancelled` 之后不再变化，
/// 取消理由也一起定格。
priv enum CancelState {
  Pending
  // 位置参数而不是 `message : String?`：MoonBit 的枚举载荷要带名字得写
  // `message~ : String?`，这里只有一个载荷，位置写法更短也够清楚。
  Cancelled(String?)
}

///|
/// 取消句柄：一个可以传给任意多次请求的「取消信号」。
///
/// 用法与 axios 的 `CancelToken` 一致，但**只有一个对象**——axios 把
/// 「传出去的 token」与「调用方手里的 source」分成两个，是为了避免拿到 token
/// 的一方误调用 `cancel`；在 MoonBit 里这层防护换来的是每次使用都多一个类型，
/// 而取消这件事本来就需要某个持有者来触发，二分的收益抵不上成本。
///
/// 几条刻意的语义：
/// - **一次性**：取消之后永远是取消状态，不能复用（与 axios 一致）；
///   需要「一次请求一个信号」就每次 `CancelToken::new()`。
/// - **可共享**：同一个 token 可以挂到多个请求上，`cancel` 一次全部生效；
///   取消发生之后才挂上来的请求会**立刻失败**，不会「取消晚了一步就照常发出」。
/// - **幂等**：重复 `cancel` 只生效第一次，第二次连理由都不会改。
///
/// `cancel` 是同步函数且不抛错，所以可以从任何地方调用——包括进度回调里
/// （它是 `noraise` 的，得不到通知就只能靠这种同步调用）。落点见
/// `docs/12-cancellation.md` 的「取消的落点」。
pub struct CancelToken {
  priv mut state : CancelState
  /// 已登记的回调槽位；取消时整组取走再清空，`None` 表示该槽位已注销。
  priv mut handles : Array[(() -> Unit)?]
  /// 递增票号，`detach` 时用来认领槽位。
  ///
  /// 只增不减：取消之后数组会被清空，旧票号一定越界，`detach` 忽略即可。
  priv mut next_ticket : Int
}

///|
/// `attach` 在「已经取消」时返回的票号：这次登记没有槽位可注销。
const NO_TICKET : Int = -1

///|
/// 新建一个尚未取消的 token。
pub fn CancelToken::new() -> CancelToken {
  { state: CancelState::Pending, handles: [], next_ticket: 0, }
}

///|
/// 取消。`message` 会原样成为这次请求失败时的错误描述（`HttpError::message`）；
/// 不传就用库的默认文案（见 `docs/04-errors.md`）。
///
/// 同步、不抛错、幂等：第一次之后的所有调用都是空操作。触发的回调按登记顺序
/// 同步执行，所以调用 `cancel` 的那条协程会等所有清理动作做完
/// （例如关闭响应体连接）才继续。
pub fn CancelToken::cancel(self : CancelToken, message? : String) -> Unit {
  match self.state {
    Cancelled(_) => ()
    Pending => {
      self.state = CancelState::Cancelled(message)
      // 先整组取走再逐个调用：回调里可能反过来注销自己——`ResponseBody::close`
      // 就会调用 `detach`，边遍历边改同一个数组会把注销写丢。
      let handles = self.handles
      self.handles = []
      for handle in handles {
        match handle {
          Some(handle) => handle()
          None => ()
        }
      }
    }
  }
}

///|
/// 是否已取消。
pub fn CancelToken::is_cancelled(self : CancelToken) -> Bool {
  match self.state {
    Pending => false
    Cancelled(_) => true
  }
}

///|
/// 取消时传入的 `message`；没取消、或取消时没给 message 时是 `None`。
///
/// 想区分「没取消」与「取消了但没给理由」用 `is_cancelled()` 配它，
/// 别用 `reason()` 的 `None` 当判断依据。
pub fn CancelToken::reason(self : CancelToken) -> String? {
  match self.state {
    Pending => None
    Cancelled(message) => message
  }
}

///|
/// 登记一个「取消时要做的事」，返回注销用的票号。
///
/// **这是给传输层用的内部机制**，不是使用者 API：一次请求在开始一段可被取消的
/// I/O 之前把自己的中断手段挂上来，结束时注销。使用者只该调 `cancel`。
///
/// 已经取消的 token 会**立刻**调用 `handle`，返回 `NO_TICKET`。这条不是顺手
/// 补的容错，而是取消语义的兜底：`cancel` 只通知得到当时登记过的句柄，而请求
/// 可能在两段 I/O 之间（重定向的两跳之间就是一个真实的时间窗）才去登记，
/// 这时它必须马上断掉，而不是照常把这跳发出去。
pub fn CancelToken::attach(
  self : CancelToken,
  handle : () -> Unit noraise,
) -> Int {
  match self.state {
    Cancelled(_) => {
      handle()
      NO_TICKET
    }
    Pending => {
      let ticket = self.next_ticket
      self.next_ticket = self.next_ticket + 1
      self.handles.push(Some(handle))
      ticket
    }
  }
}

///|
/// 注销一次登记。票号越界一律忽略——这既覆盖「重复注销」，也覆盖取消链路里
/// 的那次自注销（`cancel` 已经把数组清空，旧票号必然越界）。
pub fn CancelToken::detach(self : CancelToken, ticket : Int) -> Unit {
  if ticket >= 0 && ticket < self.handles.length() {
    self.handles[ticket] = None
  }
}

///|
/// 给这次请求挂上取消句柄，对应 axios 的 `cancelToken` / `signal`。
///
/// 与 axios 一样，token 可以来自请求级配置，也可以放在实例默认值上
/// （后者是「这个实例发出的请求共用一个取消信号」的用法）。
///
/// ```moonbit nocheck
/// let token = CancelToken::new()
/// let config = Config::new("/reports/big.csv")
///   .with_cancel_token(token)
/// // 另一处（另一个协程、或某个 UI 回调里）：
/// token.cancel(message="用户点了停止")
/// ```
pub fn Config::with_cancel_token(
  self : Config,
  cancel_token : CancelToken,
) -> Config {
  { ..self, cancel_token: Some(cancel_token), }
}
