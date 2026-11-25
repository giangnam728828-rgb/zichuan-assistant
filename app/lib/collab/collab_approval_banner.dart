// 协作审批卡：议会席位、团队队友共用的那一条横幅。
//
// 子会话的审批请求经 [CollabApprovalInbox] 收上来后，用这条卡显示「谁在
// 申请、要做什么」，并就地回答，不用切进那个子会话。

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';

import '../notify/chat_alerts.dart' show approvalText;
import 'collab_approvals.dart';

/// 一条等处理的协作审批。
class CollabApprovalBanner extends StatelessWidget {
  const CollabApprovalBanner({super.key, required this.approval, required this.onDecide});

  final CollabApproval approval;
  final void Function(ApprovalDecision decision) onDecide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            Icon(Icons.shield_outlined, size: 18, color: theme.colorScheme.onTertiaryContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${approval.label} 需要你的授权',
                    style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onTertiaryContainer),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    approvalText(approval.request),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onTertiaryContainer),
                  ),
                ],
              ),
            ),
            TextButton(onPressed: () => onDecide(ApprovalDecision.reject), child: const Text('拒绝')),
            FilledButton.tonal(
              onPressed: () => onDecide(ApprovalDecision.allowOnce),
              child: const Text('允许一次'),
            ),
          ],
        ),
      ),
    );
  }
}
