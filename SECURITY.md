# 安全策略 / Security Policy

## 报告漏洞 / Reporting a vulnerability
请通过 GitHub 的 **[Private vulnerability reporting](https://github.com/seaworld008/centos7-lighthouse/security/advisories/new)** 私下报告，不要开公开 issue。我们会尽快确认并修复。

Please report privately via GitHub private vulnerability reporting rather than a public issue.

典型的安全问题包括：
- 脚本可能泄露凭据（打印密码、把密码放进命令行参数或日志）
- 脚本可能在未提示的情况下造成数据丢失或失联
- 下载的软件没有校验签名或哈希
- 文档或示例中意外包含真实的敏感信息

## 使用者须知 / For users
- 这些脚本以 **root** 身份在生产服务器上运行。使用前请先审阅。
- 开始前做好**整机快照**，并确认云控制台的带外访问（VNC/串口）可用。
- 资产表（含密码）只放在本地，绝不提交。`.gitignore` 已默认排除 `*.xlsx`、`servers*.csv`、`inventory*.csv`、`*.pem`。
- 在 issue、讨论或实战报告里贴日志之前，先脱敏。

## 支持的版本 / Supported versions
只维护最新的 minor 版本。Only the latest minor release receives fixes.
