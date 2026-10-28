# Haoze Connect

- [下载安装包（5.0.3 正式版）](https://github.com/YIYI-16/Haoze-Connect/releases/latest)：Windows 安装版 EXE、便携版 ZIP、Android ARM64 APK。
- [客户端源码：client 分支](https://github.com/YIYI-16/Haoze-Connect/tree/client)。
- [手动构建：GitHub Actions](https://github.com/YIYI-16/Haoze-Connect/actions/workflows/haoze-build.yml)。

`main` 保存下载网页；`client` 保存 Flutter 客户端、原生工程和相关测试。
应用默认连接 `https://www.haoze.cyou`，内置登录、注册、订阅同步和流量展示，默认地区中国。

在 Actions 页面运行 **Haoze Connect Build**，选择 `windows`、`android` 或 `all`。
`source_ref` 默认是 `client`；即使从网页所在的 `main` 发起构建，也会检出客户端源码。
工作流仅上传构建附件，不自动发布 Release。

当前 Release 保留已验收安装包的原始签名与 SHA256，迁移验证的新构建产物单独保存在 Actions。
Windows 自有程序文件尚未进行可信代码签名，智能应用控制可能阻止运行；Android APK 使用测试签名，仅包含 ARM64。

本项目基于 [Hiddify](https://github.com/hiddify/hiddify-app)。
许可、署名及分发条件见 [client 分支的 LICENSE.md](https://github.com/YIYI-16/Haoze-Connect/blob/client/LICENSE.md) 和 [分发说明](https://github.com/YIYI-16/Haoze-Connect/blob/client/docs/DISTRIBUTION.md)。
