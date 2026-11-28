// GitHub 凭据的输入面板（方案第五部分 · 凭据安全）。
//
// 只做一件事：把用户粘进来的 Token 放进系统安全存储，然后关掉。
// - 输入框默认遮住，保存后立刻清空输入；
// - 说明写在面板上：不进聊天、不进日志、不进任务图；
// - 已有凭据时给「清除」，不留一份看不见的旧钥匙。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../collab/github_credentials.dart';
import '../theme/app_icons.dart';

/// 打开凭据面板；保存/清除成功返回 true。
Future<bool> showGitHubCredentialSheet(BuildContext context) async {
  final saved = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => const _GitHubCredentialSheet(),
  );
  return saved ?? false;
}

class _GitHubCredentialSheet extends ConsumerStatefulWidget {
  const _GitHubCredentialSheet();

  @override
  ConsumerState<_GitHubCredentialSheet> createState() => _GitHubCredentialSheetState();
}

class _GitHubCredentialSheetState extends ConsumerState<_GitHubCredentialSheet> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _note;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final token = _controller.text.trim();
    if (token.isEmpty) return;
    setState(() => _busy = true);
    try {
      await ref.read(gitHubCredentialsProvider).save(token);
      _controller.clear();
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _note = '没能存进安全存储：$error';
        });
      }
    }
  }

  Future<void> _clear() async {
    setState(() => _busy = true);
    await ref.read(gitHubCredentialsProvider).clear();
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(AppIcons.info, size: 18, color: colors.primary),
                const SizedBox(width: 8),
                Text('GitHub 凭据', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '只存在这台手机的系统安全存储里：不会出现在聊天、任务图、日志或错误提示中，'
              '也不会写进 git remote。提交与构建都通过接口带着它发请求。',
              style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('github-token-field'),
              controller: _controller,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Personal access token',
                hintText: 'ghp_… 或 github_pat_…',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _save(),
            ),
            if (_note case final note?)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(note, style: theme.textTheme.bodySmall?.copyWith(color: colors.error)),
              ),
            const SizedBox(height: 12),
            FilledButton(
              key: const ValueKey('github-token-save'),
              onPressed: _busy ? null : _save,
              child: Text(_busy ? '保存中…' : '保存'),
            ),
            const SizedBox(height: 4),
            TextButton(
              key: const ValueKey('github-token-clear'),
              onPressed: _busy ? null : _clear,
              child: const Text('清除已保存的凭据'),
            ),
          ],
        ),
      ),
    );
  }
}
