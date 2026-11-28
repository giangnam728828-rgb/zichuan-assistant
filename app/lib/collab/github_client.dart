// GitHub REST 客户端（方案第五部分 1–4、9–11）。
//
// 只做四件在这个 App 里**真正做得成**的事：
// 1. 认仓库、认分支、看权限（读取文件前先确认可访问）；
// 2. 读仓库里的文件（校验目标分支上确实有这个文件）；
// 3. 按路径批量提交（blobs → tree → commit → 更新 ref，不 force）；
// 4. 触发 GitHub Actions、读运行状态、取产物链接。
//
// 「改代码、跑测试」由引擎侧（bash/git）完成——这里不假装会写代码。提交接口
// 只接收**已经算好的文件字节**，调用方必须说清楚改了什么。
//
// 凭据安全：Token 只出现在 Authorization 头里；所有异常消息都不含它。

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'github_credentials.dart';

/// GitHub 的失败，按「能不能自己恢复」分类（方案第五部分 · 错误处理）。
sealed class GitHubError implements Exception {
  const GitHubError(this.message, {this.status});

  /// 给人看的一句话（绝不含 Token）。
  final String message;
  final int? status;

  @override
  String toString() => message;
}

/// 凭据缺失 / 无效 / 无权限。
final class GitHubCredentialError extends GitHubError {
  const GitHubCredentialError(super.message, {required this.problem, super.status});

  final GitHubCredentialProblem problem;

  bool get recoverable => problem != GitHubCredentialProblem.forbidden;
}

/// 仓库、分支或文件不存在（4xx 里的 404）。
final class GitHubNotFoundError extends GitHubError {
  const GitHubNotFoundError(super.message, {super.status});
}

/// 限流：等一会儿再试。
final class GitHubRateLimitError extends GitHubError {
  const GitHubRateLimitError(super.message, {this.retryAfter, super.status});

  final Duration? retryAfter;
}

/// 其它接口失败（5xx、网络、JSON 形状不对）。
final class GitHubApiError extends GitHubError {
  const GitHubApiError(super.message, {super.status});
}

/// 仓库的基本信息。
final class GitHubRepo {
  const GitHubRepo({
    required this.slug,
    required this.defaultBranch,
    required this.canPush,
    this.private = false,
    this.permissions = const {},
  });

  final String slug;
  final String defaultBranch;

  /// 这个凭据能不能往这个仓库推。
  final bool canPush;
  final bool private;
  final Map<String, bool> permissions;
}

/// 一次提交的结果。
final class GitHubCommitResult {
  const GitHubCommitResult({required this.sha, required this.branch, required this.files});

  final String sha;
  final String branch;

  /// 提交了哪些路径。
  final List<String> files;
}

/// 一次 Actions 运行。
final class GitHubRun {
  const GitHubRun({
    required this.id,
    required this.status,
    required this.conclusion,
    required this.url,
    this.headSha = '',
    this.workflowName = '',
    this.createdAt,
  });

  final int id;

  /// queued / in_progress / completed。
  final String status;

  /// success / failure / cancelled / neutral / skipped（还没结束时为空）。
  final String conclusion;
  final String url;
  final String headSha;
  final String workflowName;
  final DateTime? createdAt;

  bool get isDone => status == 'completed';

  bool get isSuccess => isDone && conclusion == 'success';

  String get label => switch (status) {
    'queued' => '排队中',
    'in_progress' => '构建中',
    'completed' => switch (conclusion) {
      'success' => '构建成功',
      'failure' => '构建失败',
      'cancelled' => '构建已取消',
      _ => '构建结束（$conclusion）',
    },
    _ => status,
  };
}

/// 一次运行的产物。
final class GitHubArtifact {
  const GitHubArtifact({
    required this.name,
    required this.sizeBytes,
    required this.downloadUrl,
    this.expired = false,
  });

  final String name;
  final int sizeBytes;

  /// 只能带凭据下载；界面只展示文件名与大小，链接不直接给外发。
  final String downloadUrl;
  final bool expired;
}

/// GitHub REST 的最小可用封装。
class GitHubClient {
  GitHubClient({
    required this.credentials,
    http.Client? httpClient,
    this.baseUrl = 'https://api.github.com',
    this.userAgent = 'zichuan-assistant',
  }) : _http = httpClient ?? http.Client();

  final GitHubCredentials credentials;
  final http.Client _http;
  final String baseUrl;
  final String userAgent;

  void close() => _http.close();

  // ---------------------------------------------------------------------------
  // 读

  /// 仓库信息（默认分支 + 这个凭据的权限）。顺带完成「能不能访问」的检查。
  Future<GitHubRepo> repo(String slug) async {
    final json = await _get('/repos/$slug');
    final permissions = <String, bool>{
      for (final entry in ((json['permissions'] as Map?) ?? const {}).entries)
        if (entry.value is bool) '${entry.key}': entry.value as bool,
    };
    return GitHubRepo(
      slug: slug,
      defaultBranch: json['default_branch'] as String? ?? 'main',
      canPush: permissions['push'] ?? false,
      private: json['private'] as bool? ?? false,
      permissions: permissions,
    );
  }

  /// 分支头部的 commit sha；分支不存在报 [GitHubNotFoundError]。
  Future<String> branchHead(String slug, String branch) async {
    final json = await _get('/repos/$slug/branches/${_segment(branch)}');
    final commit = json['commit'];
    if (commit is! Map) throw const GitHubApiError('分支信息里没有 commit');
    return commit['sha'] as String? ?? '';
  }

  /// 读一个文件（返回原始字节；base64 解码后）。
  Future<Uint8List> readFile(String slug, String path, {String? ref}) async {
    final query = ref == null ? '' : '?ref=${Uri.encodeQueryComponent(ref)}';
    final json = await _get('/repos/$slug/contents/${_path(path)}$query');
    if (json is! Map) throw GitHubNotFoundError('$path 不是一个文件');
    if (json['type'] != 'file') throw GitHubNotFoundError('$path 不是一个文件');
    final encoded = json['content'] as String? ?? '';
    if (encoded.isEmpty) return Uint8List(0);
    try {
      return base64Decode(encoded.replaceAll('\n', ''));
    } on FormatException {
      throw GitHubApiError('$path 的内容不是合法的 base64');
    }
  }

  // ---------------------------------------------------------------------------
  // 写：按路径批量提交（不用 force，分支必须已存在）

  /// 在 [branch] 上提交一组文件；文件内容由调用方给（[files] 是 path → 字节）。
  ///
  /// 只更新 ref 到新提交，`force: false`：分支被别人推过就失败，不覆盖别人的
  /// 工作。
  Future<GitHubCommitResult> commitFiles({
    required String slug,
    required String branch,
    required String message,
    required Map<String, List<int>> files,
  }) async {
    if (files.isEmpty) throw const GitHubApiError('没有要提交的文件');
    final head = await branchHead(slug, branch);

    // 1) 每个文件一个 blob。
    final entries = <Map<String, Object?>>[];
    for (final entry in files.entries) {
      final blob = await _post('/repos/$slug/git/blobs', {
        'content': base64Encode(entry.value),
        'encoding': 'base64',
      });
      final sha = blob['sha'] as String?;
      if (sha == null || sha.isEmpty) throw const GitHubApiError('创建 blob 失败');
      entries.add({'path': entry.key, 'mode': '100644', 'type': 'blob', 'sha': sha});
    }

    // 2) 在父提交的树上建新树。
    final tree = await _post('/repos/$slug/git/trees', {'base_tree': head, 'tree': entries});
    final treeSha = tree['sha'] as String?;
    if (treeSha == null || treeSha.isEmpty) throw const GitHubApiError('创建 tree 失败');

    // 3) 提交。
    final commit = await _post('/repos/$slug/git/commits', {
      'message': message,
      'tree': treeSha,
      'parents': [head],
    });
    final commitSha = commit['sha'] as String?;
    if (commitSha == null || commitSha.isEmpty) throw const GitHubApiError('创建 commit 失败');

    // 4) 移动分支（不 force）。
    await _patch('/repos/$slug/git/refs/heads/${_segment(branch)}', {'sha': commitSha, 'force': false});

    return GitHubCommitResult(sha: commitSha, branch: branch, files: files.keys.toList());
  }

  // ---------------------------------------------------------------------------
  // Actions

  /// 触发一次 workflow_dispatch（返回值没有 runId，需要再查最近一次）。
  Future<void> dispatchWorkflow(String slug, String workflow, String ref, {Map<String, String>? inputs}) =>
      _post('/repos/$slug/actions/workflows/${_segment(workflow)}/dispatches', {'ref': ref, if (inputs != null) 'inputs': inputs});

  /// 某个 workflow 在某个 ref 上最近的一次运行。
  Future<GitHubRun?> latestRun(String slug, String workflow, String branch) async {
    final json = await _get(
      '/repos/$slug/actions/workflows/${_segment(workflow)}/runs'
      '?branch=${Uri.encodeQueryComponent(branch)}&per_page=1',
    );
    final runs = (json['workflow_runs'] as List?) ?? const [];
    if (runs.isEmpty) return null;
    final first = runs.first;
    if (first is! Map) return null;
    return _run(first);
  }

  /// 单次运行的状态。
  Future<GitHubRun?> run(String slug, int runId) async {
    final json = await _get('/repos/$slug/actions/runs/$runId');
    return _run(json);
  }

  /// 运行产物。
  Future<List<GitHubArtifact>> artifacts(String slug, int runId) async {
    final json = await _get('/repos/$slug/actions/runs/$runId/artifacts');
    final list = (json['artifacts'] as List?) ?? const [];
    return [
      for (final item in list)
        if (item is Map)
          GitHubArtifact(
            name: item['name'] as String? ?? '',
            sizeBytes: (item['size_in_bytes'] as num?)?.toInt() ?? 0,
            downloadUrl: item['archive_download_url'] as String? ?? '',
            expired: item['expired'] as bool? ?? false,
          ),
    ];
  }

  /// 触发后盯住这次运行，直到结束或超时。
  ///
  /// 触发接口不返回 runId：先记下「触发前最近一次」，轮询到出现新的为止。
  Future<GitHubRun?> dispatchAndWatch({
    required String slug,
    required String workflow,
    required String branch,
    Duration timeout = const Duration(minutes: 30),
    Duration interval = const Duration(seconds: 10),
    void Function(GitHubRun run)? onUpdate,
  }) async {
    final before = await latestRun(slug, workflow, branch);
    await dispatchWorkflow(slug, workflow, branch);
    final deadline = DateTime.now().add(timeout);
    GitHubRun? current;
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(interval);
      final latest = await latestRun(slug, workflow, branch);
      if (latest == null) continue;
      if (before != null && latest.id == before.id) continue; // 还是上一次
      current = latest;
      onUpdate?.call(latest);
      if (latest.isDone) return latest;
    }
    return current;
  }

  // ---------------------------------------------------------------------------
  // HTTP

  Future<Map<String, Object?>> _get(String path) async => _send('GET', path);

  Future<Map<String, Object?>> _post(String path, Object body) async => _send('POST', path, body: body);

  Future<Map<String, Object?>> _patch(String path, Object body) async => _send('PATCH', path, body: body);

  Future<Map<String, Object?>> _send(String method, String path, {Object? body}) async {
    final token = await credentials.tokenForRequest();
    if (token == null || token.isEmpty) {
      throw const GitHubCredentialError(
        '还没有配置 GitHub 凭据：设置里填一次，之后提交和构建都用它。',
        problem: GitHubCredentialProblem.missing,
      );
    }
    final uri = Uri.parse('$baseUrl$path');
    final request = http.Request(method, uri)
      ..headers.addAll({
        'Accept': 'application/vnd.github+json',
        'Authorization': 'Bearer ${token.trim()}',
        'User-Agent': userAgent,
        'X-GitHub-Api-Version': '2022-11-28',
      });
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }

    http.StreamedResponse streamed;
    try {
      streamed = await _http.send(request);
    } on Object catch (error) {
      // 网络层错误：不把原始异常（可能含 URL）原样抛给界面。
      throw GitHubApiError('连不上 GitHub（${error.runtimeType}）');
    }
    final text = await streamed.stream.bytesToString();
    final status = streamed.statusCode;

    if (status >= 200 && status < 300) {
      if (text.trim().isEmpty) return const {};
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map<String, Object?>) return decoded;
        if (decoded is Map) return decoded.cast<String, Object?>();
        return const {};
      } on FormatException {
        throw GitHubApiError('GitHub 返回了看不懂的内容');
      }
    }

    throw _errorFor(status, text, request.headers['X-RateLimit-Reset']);
  }

  GitHubError _errorFor(int status, String body, String? rateReset) {
    var message = '';
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) message = decoded['message'] as String? ?? '';
    } on FormatException {
      // 非 JSON 错误体：只留状态码。
    }
    final limited =
        status == 429 ||
        (status == 403 && (message.toLowerCase().contains('rate limit') || message.toLowerCase().contains('secondary')));
    if (limited) {
      Duration? retry;
      if (rateReset != null) {
        final epoch = int.tryParse(rateReset);
        if (epoch != null) {
          final at = DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
          final delta = at.difference(DateTime.now());
          if (!delta.isNegative) retry = delta;
        }
      }
      return GitHubRateLimitError('GitHub 限流了，稍后再试${retry == null ? '' : '（约 ${retry.inMinutes + 1} 分钟）'}',
          retryAfter: retry, status: status);
    }
    if (status == 401) {
      return const GitHubCredentialError('GitHub 凭据无效或已过期，请重新配置', problem: GitHubCredentialProblem.invalid, status: 401);
    }
    if (status == 403) {
      return const GitHubCredentialError('这个凭据没有该仓库的写权限', problem: GitHubCredentialProblem.forbidden, status: 403);
    }
    if (status == 404) {
      return GitHubNotFoundError('找不到这个仓库、分支或文件（也可能是凭据看不到它）', status: 404);
    }
    return GitHubApiError(message.isEmpty ? 'GitHub 接口返回 $status' : 'GitHub 接口返回 $status：$message', status: status);
  }

  static GitHubRun _run(Map<Object?, Object?> json) => GitHubRun(
    id: (json['id'] as num?)?.toInt() ?? 0,
    status: json['status'] as String? ?? '',
    conclusion: json['conclusion'] as String? ?? '',
    url: json['html_url'] as String? ?? '',
    headSha: json['head_sha'] as String? ?? '',
    workflowName: json['name'] as String? ?? '',
    createdAt: DateTime.tryParse(json['created_at'] as String? ?? ''),
  );

  /// 路径里的分支/文件名要按段编码，但斜杠要保留。
  static String _segment(String value) => value.split('/').map(Uri.encodeComponent).join('/');

  static String _path(String value) => value.split('/').map(Uri.encodeComponent).join('/');
}
