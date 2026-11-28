// 把「任务」接到 GitHub 的真实结果上（方案第五部分 9–11）。
//
// 分工必须说清楚，不越界：
// - **改代码、跑测试**：引擎侧（bash/git）做，本层不假装会写代码；
// - **提交**：调用方把「已算好的文件字节」交给 [GitHubClient.commitFiles]；
// - **构建**：这里触发仓库既有的 Actions，并盯到结束，拿运行链接与产物；
// - **写回**：只有 GitHub 真的回了什么，才写进任务上下文——没有「构建成功
//   但什么凭证都没有」这种 fabricate。
//
// 错误一律转成 [CollabDeliveryResult] 里的 `error`（人话、不含 Token），
// 界面据此显示「凭据无效 / 没权限 / 限流 / 找不到仓库」。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'collab_task_context.dart';
import 'github_client.dart';
import 'github_credentials.dart';

/// 一次「触发构建并等结果」的产出。
final class CollabDeliveryResult {
  const CollabDeliveryResult({
    this.run,
    this.artifacts = const [],
    this.error,
    this.problem,
  });

  /// 盯到的最后一次运行（还没结束时也有，用于显示「构建中」）。
  final GitHubRun? run;
  final List<GitHubArtifact> artifacts;

  /// 人话的失败原因（成功时为 null）。
  final String? error;

  /// 凭据类问题（缺/无效/无权限）单独标出来，界面上好给「去配置」。
  final GitHubCredentialProblem? problem;

  bool get ok => error == null && (run?.isSuccess ?? false);

  /// 写进任务上下文的构建状态。
  String get buildStatus => switch ((run, error)) {
    (_, final error?) => error,
    (final run?, _) => run.label,
    _ => '没有拿到构建结果',
  };

  /// 第一个产物的下载链接（有就写进任务）。
  String? get artifactUrl => artifacts.isEmpty ? null : artifacts.first.downloadUrl;
}

/// 触发并观察一次构建，把结果交回给调用方去写任务。
class CollabDelivery {
  const CollabDelivery(this.client);

  final GitHubClient client;

  /// 触发 `workflow`（默认 android.yml）在 `branch` 上的一次运行，等它结束。
  ///
  /// 不传 repo/branch 就当场报「缺什么」，不会去猜一个仓库。
  Future<CollabDeliveryResult> triggerBuild({
    required String? repo,
    required String? branch,
    String workflow = 'android.yml',
    Duration timeout = const Duration(minutes: 35),
    Duration interval = const Duration(seconds: 10),
    void Function(GitHubRun run)? onUpdate,
  }) async {
    if (repo == null || repo.isEmpty) {
      return const CollabDeliveryResult(error: '没找到目标仓库：给一个 github 链接或「仓库 owner/repo」。');
    }
    if (branch == null || branch.isEmpty) {
      return const CollabDeliveryResult(error: '没找到目标分支：说一下「分支 xxx」，或者用仓库的默认分支。');
    }
    try {
      // 先确认凭据能看见这个仓库、并且有写权限（触发 Actions 需要写权限）。
      final info = await client.repo(repo);
      if (!info.canPush) {
        return const CollabDeliveryResult(
          error: '这个凭据没有该仓库的写权限（触发构建需要）。',
          problem: GitHubCredentialProblem.forbidden,
        );
      }
      final run = await client.dispatchAndWatch(
        slug: repo,
        workflow: workflow,
        branch: branch,
        timeout: timeout,
        interval: interval,
        onUpdate: onUpdate,
      );
      if (run == null) {
        return const CollabDeliveryResult(error: '已经触发，但没等到这次运行出现（可以稍后在仓库的 Actions 里看）。');
      }
      final artifacts = run.isDone ? await client.artifacts(repo, run.id) : const <GitHubArtifact>[];
      return CollabDeliveryResult(run: run, artifacts: artifacts);
    } on GitHubCredentialError catch (error) {
      return CollabDeliveryResult(error: error.message, problem: error.problem);
    } on GitHubRateLimitError catch (error) {
      return CollabDeliveryResult(error: error.message);
    } on GitHubNotFoundError catch (error) {
      return CollabDeliveryResult(error: error.message);
    } on GitHubError catch (error) {
      return CollabDeliveryResult(error: error.message);
    } on Object catch (error) {
      return CollabDeliveryResult(error: '触发构建时出错（${error.runtimeType}）');
    }
  }

  /// 只刷新已知运行的状态（不触发新的一轮）。
  Future<CollabDeliveryResult> refresh({required String? repo, required int? runId}) async {
    if (repo == null || repo.isEmpty || runId == null) {
      return const CollabDeliveryResult(error: '没有可刷新的运行。');
    }
    try {
      final run = await client.run(repo, runId);
      if (run == null) return const CollabDeliveryResult(error: '这次运行已经不在了。');
      final artifacts = run.isDone ? await client.artifacts(repo, run.id) : const <GitHubArtifact>[];
      return CollabDeliveryResult(run: run, artifacts: artifacts);
    } on GitHubError catch (error) {
      return CollabDeliveryResult(
        error: error.message,
        problem: error is GitHubCredentialError ? error.problem : null,
      );
    }
  }
}

/// 客户端（凭据只在这一层被读一次）。
final gitHubClientProvider = Provider<GitHubClient>((ref) {
  final client = GitHubClient(credentials: ref.watch(gitHubCredentialsProvider));
  ref.onDispose(client.close);
  return client;
});

final collabDeliveryProvider = Provider<CollabDelivery>(
  (ref) => CollabDelivery(ref.watch(gitHubClientProvider)),
);

/// 交付结果写回任务（字段级，避免把没拿到的覆盖成空）。
CollabTaskContext collabTaskWithDelivery(CollabTaskContext task, CollabDeliveryResult result) => task.copyWith(
  buildStatus: result.buildStatus,
  runId: result.run?.id,
  runUrl: result.run?.url,
  artifactUrl: result.artifactUrl,
  commitSha: (result.run?.headSha.isNotEmpty ?? false) ? result.run!.headSha : null,
  stage: result.error != null
      ? CollabTaskStage.failed
      : (result.run?.isDone ?? false)
      ? (result.run!.isSuccess ? CollabTaskStage.building : CollabTaskStage.failed)
      : CollabTaskStage.building,
  currentStep: result.error ?? result.buildStatus,
  failure: result.error,
);
