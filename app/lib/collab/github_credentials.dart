// GitHub 执行链路的凭据层（方案第五部分 · 凭据安全）。
//
// 规矩只有一条：**Token 只在发请求的那一刻存在**。
// - 从安全存储读（[AppSecureStorage]），读完立刻交给 [GitHubClient] 的请求头；
// - 不出现在界面、任务上下文、日志、异常消息里；
// - 不写进 git remote URL（提交走 REST API，不碰 remote）；
// - 用户可以在设置里清掉它。
//
// 任务上下文里的 `credentialRef` 只是一个键名（`github.token`），不是密钥本身。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../secrets/secure_storage.dart';

/// 凭据缺失 / 失效 / 无权限的三种情况，界面上要分开说。
enum GitHubCredentialProblem {
  /// 安全存储里没有这项：还没配。
  missing,

  /// 有，但 GitHub 说无效（401）。
  invalid,

  /// 有且有效，但这个仓库/操作没权限（403，非限流）。
  forbidden;

  String get label => switch (this) {
    GitHubCredentialProblem.missing => '还没配置 GitHub 凭据',
    GitHubCredentialProblem.invalid => 'GitHub 凭据无效或已过期',
    GitHubCredentialProblem.forbidden => '这个凭据没有该仓库的写权限',
  };
}

/// GitHub 凭据的读写。**没有任何方法把 Token 返回给界面。**
class GitHubCredentials {
  const GitHubCredentials([this._storage = const AppSecureStorage(), this._override]);

  /// 安全存储里的键名；任务上下文的 `credentialRef` 指向它。
  static const key = 'github.token';

  final AppSecureStorage _storage;

  /// 测试注入（生产为 null）。只在同一进程内用于发请求，不会被打印。
  final String? _override;

  Future<bool> hasToken() async {
    if (_override != null && _override.isNotEmpty) return true;
    try {
      final value = await _storage.read(key: key);
      return value != null && value.isNotEmpty;
    } on Object {
      return false;
    }
  }

  Future<void> save(String token) async {
    final trimmed = token.trim();
    if (trimmed.isEmpty) return;
    await _storage.write(key: key, value: trimmed);
  }

  Future<void> clear() async {
    try {
      await _storage.delete(key: key);
    } on Object {
      // 删不掉也不让界面炸：下次请求会照常报「无效」。
    }
  }

  /// 只在 [GitHubClient] 发请求时调用。
  ///
  /// 返回 null 表示没有可用凭据；调用方应转成
  /// [GitHubCredentialProblem.missing]，而不是把空串塞进请求头。
  Future<String?> tokenForRequest() async {
    if (_override != null && _override.isNotEmpty) return _override;
    try {
      final value = await _storage.read(key: key);
      if (value == null || value.isEmpty) return null;
      return value;
    } on Object {
      return null;
    }
  }

  /// 日志/错误里用的安全描述（绝不包含密钥）。
  static String describe(String? token) => token == null || token.isEmpty ? '（未配置）' : '（已配置）';
}

/// 应用内唯一的凭据入口。
final gitHubCredentialsProvider = Provider<GitHubCredentials>((ref) => const GitHubCredentials());
