# 图片握手错误的恢复与诊断

普通下载（非 archive）与阅读图片的网络失败恢复：

- 每页一次初始尝试，最多三次自动重试，退避 1 / 2 / 4 秒。
- 重试次数在真实失败时增加，不再依赖页码或“是否刷新链接”。
- `WRONG_VERSION_NUMBER` 另有可关闭的端点兼容层：一次严格验证的无 SNI
  后备连接、快速换源及短时避让，详见 `image-endpoint-compatibility.md`。
  普通瞬时错误仍使用下面的三次失败换源阈值。
- 每次尝试仍先检查阅读缓存；没有缓存才刷新链接，累计三次失败后带
  最新 sourceId 换源。首张、尾张、单页任务一视同仁。
- 恢复未完成且已解析过的数据库行时刷新链接；不改已完成行或文件。
- 移除无流量几秒后重启整个画廊的监控逻辑。各页独立重试，其他页继续完成；
  本轮全部处理完仍有失败页则暂停任务，保留已下载内容，等待用户主动恢复。
- 429/509 等限额错误与文件保存错误不进入普通网络自动重试。

## 报错后的手动重试

自动重试耗尽不是永久终止，也不会删除任务或清空进度：

- 下载卡片显示“重试”，点击后仅重新尝试未完成页，并获得新的自动重试预算。
- 4 次是单轮自动尝试的上限，不是任务的总次数上限；每次手动重试都会重新计数。
- 用户主动暂停的任务显示“继续”；重启 App 后仍能从暂停状态继续。
- 普通下载的失败、取消和暂停状态都调用普通下载的恢复流程，不调用 archive。
- 长按菜单提供“重试未完成页”；“全部重新下载”是另一个明确标注的操作，
  不应为了重试失败页而使用它。

## 超时

Dio 配置中的数字单位是毫秒，而不是秒。阅读图片使用独立拥有的
HTTP client，连接/响应头最多 5 秒，数据读取允许 20 秒无数据，
一次传输总时限 2 分钟；每个阅读地址最多再尝试两次，UI 最多自动换源一次，
即单次显示最多 6 次图片网络尝试，之后显示失败并等待手动操作。
预加载没有 UI 换源循环，每个地址最多 3 次尝试。
阅读和预加载沿用原有 `cacheimage` 目录，兼容旧自定义 key，并以实际宽高
统一新重采样图 key（详见 `download-cache-diagnostics.md`）；
只有成功取得并能创建 codec 的图片数据才原子写入缓存。

超时/取消会关闭该请求的 client，不会关闭其他页的连接。
**底层限制：Dart 的 `ConnectionTask.cancel()` 在已经进入 TLS 握手且对方
完全无响应时，不保证立即回收对应 TCP socket。**
本改动保证应用请求按时结束、不会无限重新调度；不能据此宣称所有底层
TLS socket 都立即释放。HTTP 等待响应头和读取响应体阶段的连接关闭已有
回环测试验证。未采用未经验证的 isolate 或原生传输替代方案。

## 代理与安全

阅读与预加载使用 App 配置的 DIRECT / HTTP / SOCKS 代理，而不是另行使用
一个忽略 App 代理的共享图片 client。现有证书策略保持不变，本次没有为了
处理 `WRONG_VERSION_NUMBER` 强制降低 TLS 版本或关闭更多证书验证；
阅读的 HTTPS 重定向也不会降级到 HTTP。

首次握手失败的具体节点或网络设备仍需结合实机日志确认。
`WRONG_VERSION_NUMBER` 不能单凭名字诊断为“客户端 TLS 版本太旧”。

## 脱敏诊断

使用 `--dart-define=FE_DOWNLOAD_DIAGNOSTICS=true` 开启。
主日志 `download-diagnostics.log` 保留约 1 MiB，以及一个轮转副本。

新增信息包括：

- `http_request/http_response/http_error`：API 或下载、adapter、代理类型、
  scheme/host/port、HTTP 状态、耗时。
- `page_retry/page_retry_exhausted/task_paused_after_errors`：失败次数、
  重试预算与退避、最终暂停。
- `reader_network_start/reader_network_complete/reader_network_error/reader_retry`：
  阅读/预加载、连接或响应体阶段、重定向后的端点、字节数与原始异常类别。

不会记录完整 URL、path/query、Cookie、代理地址和凭据、sourceId 或漫画标题。
TLS 分类同时检查 HandshakeException 的 OSError，但只保存固定分类名称。
不要开启全量 HTTP header/body 日志来替代这份诊断。

## 回归测试

`test/download/handshake_recovery_test.dart` 覆盖首张、尾张、单页、有限失败、
手动恢复、重试途中缓存到达、退避取消及非重试错误。
`test/network/` 覆盖超时单位、真实回环超时/取消、实际图片 codec、
读写旧缓存格式及原始异常传播。原有下载/SAF/缓存回归仍需一并通过。
