// 取消原语：`AbortController`（发起方持有）与 `AbortSignal`（随请求走）。
//
// 为什么是这一套：axios 早已不推荐自造的 `CancelToken`，改用平台的
// `AbortController` —— 发起方与观察方分成两个对象（谁有权叫停、谁只能观察），
// 状态查询走 `aborted` / `reason`，取消理由挂在信号上。本项目按这个形态复刻，
// 签名与 JS 一一对应（对照表见 `docs/12-cancellation.md`）。
//
// 本包只装**状态**，没有底层机制：信号记「取消没取消」「理由是什么」以及一组
// 登记，真正打断一次请求的协程取消发生在 transport 包（那里才有 `@async`）。
// 这样取消的语义（谁能取消、取消之后读到什么）能用纯同步用例钉死，而本包始终
// 不依赖 async 运行时——与 headers / url 一样是纯逻辑叶子包。
//
// `AbortError` 也定义在这里：`throw_if_aborted()` 需要它，而本包不能引用根包的
// `HttpError`。它**不跨库边界**——根包在唯一一处接壤（`client.mbt` 的
// `check_cancelled`）把它归一成 `HttpError(ERR_CANCELED)`，所以使用者只会看到
// 一套错误体系。

///|
/// 取消失败：`AbortSignal::throw_if_aborted` 抛出它，载荷就是 `signal.reason()`
/// （取消时没给理由就是 `None`）。
///
/// 对应 JS 里 `throwIfAborted()` 抛出的那个 `AbortError`（一个 DOMException）。
/// 差别只有形态：那边是 `reason: any` 原样抛出，这里收纳成字符串——与本项目
/// 「理由落成错误文案、文案只在错误层一处」的既有链路一致（`src/http_error.mbt`）。
///
/// 这个类型只在 abort 包与根包之间流转，不是对外的错误：使用者从库接口拿到的
/// 仍然是 `HttpError`（`is_cancelled()` 为真、错误码 `ERR_CANCELED`）。
pub(all) suberror AbortError {
  Aborted(String?)
}

///|
/// 信号的状态。一次性的：从 `Pending` 走到 `Aborted` 之后不再变化，
/// 取消理由也一起定格。
priv enum AbortState {
  Pending
  // 位置参数而不是 `reason~ : String?`：MoonBit 的枚举载荷要带名字就得写
  // `reason~ : String?`，这里只有一个载荷，位置写法更短也够清楚。
  Aborted(String?)
}

///|
/// 取消信号：一个可以传给任意多次请求的「取消观察口」。
///
/// 它自己**不能**被取消——叫停只能由持有 `AbortController` 的一方发起
/// （对应 JS 的 `controller.abort()`）。这条分工正是这套机制比 `CancelToken`
/// 好的地方：拿到信号的代码只能观察，「误调用取消」在类型上就写不出来。
///
/// 几条刻意的语义（与 JS 一致）：
/// - **一次性**：取消之后永远是取消状态，不能复用；需要「一次请求一个信号」
///   就每次 `AbortController::new()`。
/// - **可共享，但只能按请求显式共享**：同一个信号可以挂在任意多次调用上，
///   `abort` 一次全部生效。它**不会**被实例默认值继承——信号是一次性的，
///   放进实例默认值会让那个实例之后的所有请求一起失效，所以本项目的
///   三个入口只从 `signal?` 参数收信号（理由见 `docs/12-cancellation.md`）。
/// - **取消晚一步也算数**：取消发生之后才开始的请求会**立刻失败**，不会
///   「取消晚了一步就照常发出去」——靠的是每个可取消的 I/O 入口先查
///   `aborted()`（见 `attach` 的说明与 `docs/12-cancellation.md` 的「两条兜底」）。
/// - **幂等**：重复 `abort` 只生效第一次，第二次连理由都不会改。
pub struct AbortSignal {
  priv mut state : AbortState
  /// 已登记的回调槽位；取消时整组取走再清空，`None` 表示该槽位已注销。
  priv mut handles : Array[(() -> Unit)?]
  /// 递增票号，`detach` 时用来认领槽位。
  ///
  /// 只增不减：取消之后数组会被清空，旧票号一定越界，`detach` 忽略即可。
  priv mut next_ticket : Int
}

///|
/// 取消的**发起方**：谁造出它，谁就有权叫停拿着它信号的那些请求。
///
/// 与 JS 一样分成两个对象，是为了把「能取消」变成一项持有能力：信号可以到处传
/// （进配置、进传输层、交给别的库），控制器留在需要叫停的一方手里。
pub struct AbortController {
  priv signal : AbortSignal
}

///|
/// `attach` 在「已经取消」时返回的票号：这次登记没有槽位可注销。
const NO_TICKET : Int = -1

///|
/// 新建一个尚未取消的控制器（它的信号也尚未取消）。
pub fn AbortController::new() -> AbortController {
  { signal: AbortSignal::new(), }
}

///|
/// 取出这个控制器的信号，对应 JS 的 `controller.signal`。
///
/// 给出去的信号与控制器共享状态：`abort()` 之后，任何拿着这个信号的一方
/// 都会看到取消（MoonBit 里带可变字段的类型是引用语义，副本指同一份状态）。
pub fn AbortController::signal(self : AbortController) -> AbortSignal {
  self.signal
}

///|
/// 发起取消，对应 JS 的 `controller.abort(reason)`。
///
/// `reason` 会原样成为这次请求失败时的错误描述（`HttpError::message()`）；
/// 不传就用库的默认文案（见 `docs/04-errors.md`）。
///
/// 同步、不抛错、幂等：第一次之后的所有调用都是空操作。触发的登记按登记顺序
/// 同步执行，所以调用 `abort` 的那条协程会等所有清理动作做完
/// （例如关闭响应体连接）才继续。
///
/// ```moonbit nocheck
/// let controller = AbortController::new()
/// // 信号按请求传（它是入口的 signal? 参数，不属于配置）：
/// client.request(Config::new("/reports/big.csv"), signal=controller.signal())
/// // 另一处（另一个协程、或某个 UI 回调里）：
/// controller.abort(reason="用户点了停止")
/// ```
pub fn AbortController::abort(self : AbortController, reason? : String) -> Unit {
  self.signal.abort_with(reason)
}

///|
/// 新建一个尚未取消的信号。
///
/// **不公开**：与 JS 一致，信号只能从控制器或静态构造（`AbortSignal::abort`）
/// 拿到——否则「谁有权叫停」这项能力就漏了。
fn AbortSignal::new() -> AbortSignal {
  { state: AbortState::Pending, handles: [], next_ticket: 0, }
}

///|
/// 造一个**出生就已取消**的信号，对应 JS 的 `AbortSignal.abort(reason)`。
///
/// 用途是把「已经不该再发请求了」变成一个可以到处传的值：上游判定整体超时之后
/// 给后续所有请求都挂上它；测试里也省掉「先造控制器再取消」那一步。
pub fn AbortSignal::abort(reason? : String) -> AbortSignal {
  let signal = AbortSignal::new()
  signal.abort_with(reason)
  signal
}

///|
/// 落地一次取消：状态翻到已取消，并按登记顺序触发全部登记。
///
/// 私有：取消的发起口只有 `AbortController::abort` 与 `AbortSignal::abort`
/// 静态构造这两处（与 JS 一致，信号自己不带 abort 方法）。
fn AbortSignal::abort_with(self : AbortSignal, reason : String?) -> Unit {
  match self.state {
    Aborted(_) => ()
    Pending => {
      self.state = AbortState::Aborted(reason)
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
/// 是否已取消，对应 JS 的 `signal.aborted`。
///
/// 它问的是「取消这件事发生了没有」，不是「这次请求失败了没有」——所以要区分
/// 「没取消」与「取消了但没给理由」时，用 `aborted()` 配 `reason()`。
pub fn AbortSignal::aborted(self : AbortSignal) -> Bool {
  self.state is Aborted(_)
}

///|
/// 取消时传入的 reason；没取消、或取消时没给 reason 时是 `None`。
///
/// 对应 JS 的 `signal.reason`（那边默认是一个 `AbortError` 异常对象；这里简化成
/// 字符串，默认文案由错误层统一给）。
pub fn AbortSignal::reason(self : AbortSignal) -> String? {
  match self.state {
    Pending => None
    Aborted(reason) => reason
  }
}

///|
/// 已取消就抛 `AbortError`（载荷是取消理由），没取消就什么都不做，
/// 对应 JS 的 `signal.throwIfAborted()`。
///
/// 这是「每干一段之前先查一眼」的写法，串行流程里不必给每一步都手写
/// `if signal.aborted() { ... }`。
///
/// 抛出的 `AbortError` 不是对外的错误类型：它只在 abort 包与根包之间流转，
/// 根包在管线入口把它归一成 `HttpError`（`ERR_CANCELED`），
/// 见 `docs/12-cancellation.md` 的「取消长什么样」。
///
/// ```moonbit nocheck
/// // 串行流程里，每段开头查一次；已经取消就抛 AbortError
/// signal.throw_if_aborted()
/// ```
pub fn AbortSignal::throw_if_aborted(
  self : AbortSignal,
) -> Unit raise AbortError {
  match self.state {
    Pending => ()
    Aborted(reason) => raise AbortError::Aborted(reason)
  }
}

///|
/// 登记一个「取消时要做的事」，返回注销用的票号（`detach` 按票号注销）——
/// 对应 JS 的 `signal.addEventListener("abort", handle)` 与 `removeEventListener`。
///
/// **这是给传输层用的内部机制**，不是使用者 API：一次请求在开始一段可被取消的
/// I/O 之前把自己的中断手段挂上来，结束时注销。使用者只该观察
/// （`aborted()` / `reason()`），叫停由控制器发起。
///
/// 两条与 JS 一致、且与旧 `CancelToken` 不同的语义：
/// - **已取消的信号上登记不会触发**（JS 的 `addEventListener` 在 `aborted` 之后
///   也不会补触发）**，也不会被保留**——没有会触发它的未来，留着只会拖住闭包。
///   所以「取消晚一步」的兜底是**登记点自己先查 `aborted()`**，不是登记的副作用：
///   重定向两跳之间、两次响应体读取之间都靠这条（见 `docs/12-cancellation.md`）；
/// - 触发时按登记顺序同步执行（顺序确定才好推理）。
pub fn AbortSignal::attach(
  self : AbortSignal,
  handle : () -> Unit noraise,
) -> Int {
  match self.state {
    Aborted(_) => NO_TICKET
    Pending => {
      let ticket = self.next_ticket
      self.next_ticket = self.next_ticket + 1
      self.handles.push(Some(handle))
      ticket
    }
  }
}

///|
/// 注销一次登记，对应 JS 的 `removeEventListener`。
///
/// 票号越界一律忽略——这既覆盖「重复注销」，也覆盖取消链路里的那次自注销
/// （`abort_with` 已经把数组整组取走，旧票号必然越界），
/// 以及「已取消信号上登记未保留」时拿到的 `NO_TICKET`。
pub fn AbortSignal::detach(self : AbortSignal, ticket : Int) -> Unit {
  if ticket >= 0 && ticket < self.handles.length() {
    self.handles[ticket] = None
  }
}
