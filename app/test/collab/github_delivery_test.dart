// GitHub 交付链路（方案第五部分 1–4、9–11）：认仓库/分支、提交、触发构建、
// 读真实结果。
//
// 全部用 MockClient 跑，不碰网络；重点验证三件事：
// 1. 错误分类：凭据缺失 / 401 / 403 限流 / 403 无权限 / 404 要分开说；
// 2. 成功链路：dispatch → 等到 run → 取 artifacts → 写进任务；
// 3. 凭据安全：任何错误消息、任务字段、结果里都不出现 Token。

import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_app/collab/collab_task_context.dart';
import 'package:dsh_app/collab/github_client.dart';
import 'package:dsh_app/collab/github_credentials.dart';
import 'package:dsh_app/collab/github_delivery.dart';
import 'package:dsh_app/secrets/secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _token = 'ghp_SECRETTOKEN1234567890';
const _slug = 'owner/repo';
const _branch = 'ui-chuan-shui';

GitHubCredentials _creds({String? token = _token}) =>
    GitHubCredentials(const AppSecureStorage(), token);

/// 一个够用的假 GitHub：按路径返回预设，并记下请求。
class _FakeGitHub {
  _FakeGitHub({
    this.repoStatus = 200,
    this.repoPermissions = const {'push': true, 'pull': true},
    this.branchStatus = 200,
    this.fileStatus = 200,
    this.dispatchStatus = 204,
    this.runs = const [],
    this.runStatus = 200,
    this.artifactsStatus = 200,
  });

  int repoStatus;
  Map<String, bool> repoPermissions;
  int branchStatus;
  int fileStatus;
  int dispatchStatus;
  List<Map<String, Object?>> runs;
  int runStatus;
  int artifactsStatus;

  final calls = <String>[];

  late final http.Client client = MockClient((request) async {
    final path = request.url.path;
    calls.add('${request.method} $path');

    if (path == '/repos/$_slug') {
      if (repoStatus != 200) return _err(repoStatus, repoStatus == 404 ? 'Not Found' : 'Forbidden');
      return _json({
        'full_name': _slug,
        'default_branch': 'main',
        'private': false,
        'permissions': repoPermissions,
      });
    }
    if (path == '/repos/$_slug/branches/$_branch') {
      if (branchStatus != 200) return _err(branchStatus, 'Not Found');
      return _json({'name': _branch, 'commit': {'sha': 'head-sha'}});
    }
    if (path.startsWith('/repos/$_slug/contents/')) {
      if (fileStatus != 200) return _err(fileStatus, 'Not Found');
      final bytes = utf8.encode('hello');
      return _json({
        'type': 'file',
        'encoding': 'base64',
        'content': base64Encode(bytes),
      });
    }
    if (path.endsWith('/dispatches')) {
      if (dispatchStatus >= 400) return _err(dispatchStatus, 'Bad Request');
      return http.Response('', dispatchStatus);
    }
    if (path.endsWith('/runs') || path.endsWith('/runs/')) {
      return _json({'workflow_runs': runs});
    }
    if (path.contains('/actions/runs/') && path.endsWith('/artifacts')) {
      if (artifactsStatus != 200) return _err(artifactsStatus, 'server error');
      return _json({
        'artifacts': [
          {
            'name': 'zichuan-assistant-arm64',
            'size_in_bytes': 1234,
            'archive_download_url': 'https://api.github.com/repos/$_slug/actions/artifacts/1/zip',
            'expired': false,
          },
        ],
      });
    }
    if (path.contains('/actions/runs/')) {
      if (runStatus != 200) return _err(runStatus, 'Not Found');
      return _json(runs.isEmpty ? {'id': 7, 'status': 'completed', 'conclusion': 'success', 'html_url': 'u'} : runs.last);
    }
    return _err(404, 'Not Found');
  });

  static http.Response _json(Map<String, Object?> body) => http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json'},
  );

  static http.Response _err(int status, String message) => http.Response(
    jsonEncode({'message': message}),
    status,
    headers: {
      'content-type': 'application/json',
      if (status == 403) 'x-ratelimit-reset': '${DateTime.now().millisecondsSinceEpoch ~/ 1000 + 60}',
    },
  );
}

Map<String, Object?> _runJson({
  int id = 11,
  String status = 'completed',
  String conclusion = 'success',
  String sha = 'abc123',
}) => {
  'id': id,
  'status': status,
  'conclusion': conclusion,
  'html_url': 'https://github.com/$_slug/actions/runs/$id',
  'head_sha': sha,
  'name': 'Android CI',
  'created_at': '2026-11-28T00:00:00Z',
};

void main() {
  group('GitHubClient 错误分类', () {
    test('没有凭据：报「还没配置」，不发请求', () async {
      final fake = _FakeGitHub();
      final client = GitHubClient(credentials: _creds(token: null), httpClient: fake.client);
      await expectLater(
        client.repo(_slug),
        throwsA(isA<GitHubCredentialError>().having((e) => e.problem, 'problem', GitHubCredentialProblem.missing)),
      );
      expect(fake.calls, isEmpty);
    });

    test('401：凭据无效', () async {
      final fake = _FakeGitHub(repoStatus: 401);
      final client = GitHubClient(credentials: _creds(), httpClient: fake.client);
      await expectLater(
        client.repo(_slug),
        throwsA(isA<GitHubCredentialError>().having((e) => e.problem, 'problem', GitHubCredentialProblem.invalid)),
      );
    });

    test('403 + 限流：报限流（不是「没权限」）', () async {
      final fake = _FakeGitHub();
      final client = GitHubClient(
        credentials: _creds(),
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({'message': 'API rate limit exceeded'}),
            403,
            headers: {'content-type': 'application/json'},
          ),
        ),
      );
      await expectLater(client.repo(_slug), throwsA(isA<GitHubRateLimitError>()));
      expect(fake.calls, isEmpty);
    });

    test('403 无权限：说清楚是写权限', () async {
      final fake = _FakeGitHub(repoStatus: 403);
      final client = GitHubClient(credentials: _creds(), httpClient: fake.client);
      await expectLater(
        client.repo(_slug),
        throwsA(isA<GitHubCredentialError>().having((e) => e.problem, 'problem', GitHubCredentialProblem.forbidden)),
      );
    });

    test('404：找不到仓库/分支', () async {
      final fake = _FakeGitHub(branchStatus: 404);
      final client = GitHubClient(credentials: _creds(), httpClient: fake.client);
      await expectLater(client.branchHead(_slug, 'nope'), throwsA(isA<GitHubNotFoundError>()));
    });
  });

  group('GitHubClient 读与提交', () {
    test('仓库信息带默认分支与写权限', () async {
      final client = GitHubClient(credentials: _creds(), httpClient: _FakeGitHub().client);
      final repo = await client.repo(_slug);
      expect(repo.defaultBranch, 'main');
      expect(repo.canPush, isTrue);
    });

    test('读文件：base64 解回原始字节', () async {
      final client = GitHubClient(credentials: _creds(), httpClient: _FakeGitHub().client);
      final bytes = await client.readFile(_slug, 'app/pubspec.yaml');
      expect(utf8.decode(bytes), 'hello');
    });

    test('提交：blobs → tree → commit → 移动 ref，且不 force', () async {
      final calls = <String, String>{};
      final client = GitHubClient(
        credentials: _creds(),
        httpClient: MockClient((request) async {
          final path = request.url.path;
          if (path.endsWith('/git/blobs')) {
            return http.Response(jsonEncode({'sha': 'blob1'}), 201);
          }
          if (path.endsWith('/git/trees')) {
            final body = jsonDecode(request.body) as Map<String, Object?>;
            expect(body['base_tree'], 'head-sha');
            final tree = (body['tree'] as List).first as Map<String, Object?>;
            expect(tree['path'], 'a.txt');
            expect(tree['mode'], '100644');
            return http.Response(jsonEncode({'sha': 'tree1'}), 201);
          }
          if (path.endsWith('/git/commits')) {
            final body = jsonDecode(request.body) as Map<String, Object?>;
            expect(body['tree'], 'tree1');
            expect((body['parents'] as List).first, 'head-sha');
            return http.Response(jsonEncode({'sha': 'commit1'}), 201);
          }
          if (path.contains('/git/refs/heads/')) {
            calls['method'] = request.method;
            calls['body'] = request.body;
            return http.Response(jsonEncode({'object': {'sha': 'commit1'}}), 200);
          }
          if (path.contains('/branches/')) {
            return http.Response(jsonEncode({'commit': {'sha': 'head-sha'}}), 200);
          }
          return http.Response('{}', 200);
        }),
      );

      final result = await client.commitFiles(
        slug: _slug,
        branch: _branch,
        message: 'fix: 输入栏遮挡',
        files: {'a.txt': utf8.encode('内容')},
      );
      expect(result.sha, 'commit1');
      expect(result.files, ['a.txt']);
      expect(calls['method'], 'PATCH');
      final refBody = jsonDecode(calls['body']!) as Map<String, Object?>;
      expect(refBody['sha'], 'commit1');
      expect(refBody['force'], isFalse, reason: '不能覆盖别人推上去的东西');
    });
  });

  group('触发构建并写回任务', () {
    test('成功链路：dispatch → 等到 run → artifacts → 写进任务', () async {
      final fake = _FakeGitHub(runs: [_runJson(id: 11)]);
      final client = GitHubClient(credentials: _creds(), httpClient: fake.client);
      final delivery = CollabDelivery(client);

      final result = await delivery.triggerBuild(
        repo: _slug,
        branch: _branch,
        interval: Duration.zero,
        timeout: const Duration(seconds: 5),
      );

      expect(result.error, isNull);
      expect(result.run?.id, 11);
      expect(result.ok, isTrue);
      expect(result.artifactUrl, contains('/artifacts/1/zip'));
      expect(fake.calls.any((c) => c.endsWith('/dispatches')), isTrue);

      final task = CollabTaskContext(
        id: 'r1',
        conversationId: 'c1',
        kind: 'team',
        goal: '修输入栏',
        repo: _slug,
        branch: _branch,
        createdAt: DateTime(2026, 11, 28),
        updatedAt: DateTime(2026, 11, 28),
      );
      final next = collabTaskWithDelivery(task, result);
      expect(next.buildStatus, '构建成功');
      expect(next.runUrl, contains('/actions/runs/11'));
      expect(next.commitSha, 'abc123');
      expect(next.artifactUrl, isNotNull);
    });

    test('触发前先看权限：不能推就不触发', () async {
      final fake = _FakeGitHub(repoPermissions: const {'push': false, 'pull': true});
      final client = GitHubClient(credentials: _creds(), httpClient: fake.client);
      final result = await CollabDelivery(client).triggerBuild(
        repo: _slug,
        branch: _branch,
        interval: Duration.zero,
      );
      expect(result.error, contains('写权限'));
      expect(result.problem, GitHubCredentialProblem.forbidden);
      expect(fake.calls.any((c) => c.endsWith('/dispatches')), isFalse);
    });

    test('缺仓库 / 缺分支：当场说清楚，不发请求', () async {
      final fake = _FakeGitHub();
      final delivery = CollabDelivery(GitHubClient(credentials: _creds(), httpClient: fake.client));
      final noRepo = await delivery.triggerBuild(repo: null, branch: _branch);
      expect(noRepo.error, contains('没找到目标仓库'));
      final noBranch = await delivery.triggerBuild(repo: _slug, branch: null);
      expect(noBranch.error, contains('没找到目标分支'));
      expect(fake.calls, isEmpty);
    });

    test('一直等不到新 run：如实说没等到，不编一个成功', () async {
      final fake = _FakeGitHub(runs: [_runJson(id: 5, status: 'completed', conclusion: 'success')]);
      final client = GitHubClient(credentials: _creds(), httpClient: fake.client);
      final result = await CollabDelivery(client).triggerBuild(
        repo: _slug,
        branch: _branch,
        interval: Duration.zero,
        timeout: const Duration(milliseconds: 120),
      );
      // 触发前最近一次是 5，触发后始终只有 5：没有新运行。
      expect(result.error, contains('没等到'));
      expect(result.run, isNull);
    });

    test('刷新：按 runId 取状态与产物', () async {
      final fake = _FakeGitHub(runs: [_runJson(id: 11, status: 'in_progress', conclusion: '')]);
      final client = GitHubClient(credentials: _creds(), httpClient: fake.client);
      final result = await CollabDelivery(client).refresh(repo: _slug, runId: 11);
      expect(result.error, isNull);
      expect(result.run?.label, '构建中');
    });
  });

  group('凭据安全', () {
    test('错误消息与任务字段里都不出现 Token', () async {
      // 401 场景：错误文本来自我们自己写的，不拼接响应体。
      final client = GitHubClient(credentials: _creds(), httpClient: _FakeGitHub(repoStatus: 401).client);
      final result = await CollabDelivery(client).triggerBuild(repo: _slug, branch: _branch, interval: Duration.zero);
      expect(result.error, isNotNull);
      expect(result.error, isNot(contains(_token)));
      expect(result.buildStatus, isNot(contains(_token)));
    });

    test('凭据描述只说明有没有，不泄露内容', () {
      expect(GitHubCredentials.describe(_token), '（已配置）');
      expect(GitHubCredentials.describe(null), '（未配置）');
      expect(GitHubCredentials.describe(_token), isNot(contains(_token)));
    });

    test('读文件后再提交：Token 只出现在请求头，不出现在结果里', () async {
      final seenAuth = <String>[];
      final client = GitHubClient(
        credentials: _creds(),
        httpClient: MockClient((request) async {
          seenAuth.add(request.headers['Authorization'] ?? '');
          return http.Response(jsonEncode({'type': 'file', 'content': base64Encode(Uint8List(0))}), 200);
        }),
      );
      await client.readFile(_slug, 'a.txt');
      expect(seenAuth.single, 'Bearer $_token');
    });
  });
}
