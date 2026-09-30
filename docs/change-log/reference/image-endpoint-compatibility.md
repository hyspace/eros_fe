# 图片端点快速换源与短时避让

普通下载、阅读和预加载先检查缓存，再使用正常 TLS 和 App 配置的代理。
2026-09-29 已从当前源码移除 Android 无 SNI 后备连接、平台桥接和专用依赖；
不再支持 `FE_IMAGE_SNI_COMPAT`。历史设计见 [008](../008-temporary-tls-compatibility.md)，
移除依据与验证限制见 [010](../010-remove-sni-fallback.md)。

## 保留的编译开关

`FE_IMAGE_FAST_FAILOVER` 默认开启，可关闭快速换源与短时避让：

```sh
--dart-define=FE_IMAGE_FAST_FAILOVER=false
```

它不改变 TLS 握手、证书策略、缓存格式、数据库或用户数据。
关闭它不会重新启用无 SNI 路径，只恢复普通的有限重试/换源策略。

## 请求与恢复顺序

1. 查缓存；命中时不联网。
2. 未被短时避让的端点只走正常传输，不追加无 SNI 连接。
3. 仅在 `HandshakeException`（可包在 DioException 中）明确包含
   `WRONG_VERSION_NUMBER` 时，尽早请求新 sourceId，不反复重试相同来源。
4. 对 HTTPS H@H 图片端点，按完整主机、端口和代理路径记录 60 秒避让，
   最多 128 条；不封禁整个后缀，也不隔离 fullimg 的主站/API 域名。
5. 到期、重启或显式点击普通下载的重试/继续后，可以重新尝试该端点。

阅读与预加载仍最多自动换源一次，原图不退化成重采样图；普通下载继续遵守
每页最多四次尝试的预算。无 SNI 移除不影响缓存优先和已完成文件的保留。
其他瞬时错误保持原有有限重试，证书错误不被误分类成 wrong-version 快速换源。

## 代理、证书与资源释放

- 正常传输继续尊重 App 的 DIRECT / HTTP / SOCKS 配置，不另建直连后备。
- 不抑制 SNI、不降级 TLS/HTTP、不扩大既有证书放行策略。
- **正常 IO 原本的 `skipCertificate` 配置仍存在**；删除严格校验的兼容层
  不等于全面收紧整个 App 的证书策略。本次真实端点测试明确开启证书验证。
- 请求的 method、body、Range 和 Host 不因恢复策略被重写。
- 各图片请求独立持有 client，成功读完、失败或取消后释放；关闭 adapter
  会关闭其活动 client，不新增原生流式会话。
- Dart 在对端完全无响应的 TLS 握手中，底层 socket 的立即释放仍有限制，
  详见 [握手恢复指南](handshake-recovery.md)。

## 诊断与测试

`FE_DOWNLOAD_DIAGNOSTICS=true` 仍记录普通网络与缓存事件，以及
`image_host_cooldown` / `image_host_avoided`。避让不代表新发起一次 TCP 连接。
当前代码不再生成 `sni_compat_start/headers/failed`；旧日志里的这些事件仍是
历史兼容连接证据，不能按新版行为重新解释。

回归覆盖单次正常传输、错误原因保留、无额外后备连接、精确端点/代理隔离、
到期与手动清除、关闭开关、请求内容保留、取消、预加载一次换源，以及既有
真实回环超时/取消、缓存和下载恢复。故障返回 404 的根路径重测只验证 TLS/HTTP，
不替代真实图片、完整阅读或整本下载验收。
