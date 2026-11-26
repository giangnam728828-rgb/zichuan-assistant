// 备份与恢复: the person's own data in this phone's preferences, exported as
// one JSON file through the share sheet and written back by scope. Keys and
// credentials (API keys, tokens, passwords) never enter a backup.

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/l10n.dart';
import '../../state/app_info.dart';
import '../../state/data_backup.dart';
import 'index/spots.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'settings_widgets.dart';

String _scopeLabel(L10n l10n, BackupScope scope) => switch (scope) {
  BackupScope.chat => l10n.dataBackupScopeChat,
  BackupScope.appearance => l10n.dataBackupScopeAppearance,
  BackupScope.voice => l10n.dataBackupScopeVoice,
  BackupScope.notify => l10n.dataBackupScopeNotify,
  BackupScope.models => l10n.dataBackupScopeModels,
  BackupScope.plugins => l10n.dataBackupScopePlugins,
  BackupScope.remote => l10n.dataBackupScopeRemote,
  BackupScope.other => l10n.dataBackupScopeOther,
};

class DataBackupPage extends ConsumerStatefulWidget {
  const DataBackupPage({super.key});

  @override
  ConsumerState<DataBackupPage> createState() => _DataBackupPageState();
}

class _DataBackupPageState extends ConsumerState<DataBackupPage> {
  /// Everything is ticked at first: a backup people have to configure is one
  /// they don't take.
  Set<BackupScope> _selected = {...BackupScope.values};
  Map<BackupScope, int> _counts = const {};
  DateTime? _lastExport;
  bool _busy = false;

  /// A restore wrote something; the running providers still hold the old
  /// values, so the page says what to do about it.
  bool _restored = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final counts = await countBackupEntries();
    final prefs = await SharedPreferences.getInstance();
    final last = DateTime.tryParse(prefs.getString(lastBackupKey) ?? '');
    if (!mounted) return;
    setState(() {
      _counts = counts;
      _lastExport = last?.toLocal();
    });
  }

  void _notice(String text) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _export() async {
    if (_busy) return;
    final l10n = context.l10n;
    if (_selected.isEmpty) {
      _notice(l10n.dataBackupPickScope);
      return;
    }
    setState(() => _busy = true);
    try {
      final backup = await collectBackup(scopes: _selected, appVersion: AppInfo.version);
      if (backup.values.isEmpty) {
        _notice(l10n.dataBackupEmpty);
        return;
      }
      final dir = await getTemporaryDirectory();
      final file = await writeBackupFile(backup, dir: dir);
      final name = backupFileName(backup.createdAt);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'application/json', name: name)],
          fileNameOverrides: [name],
        ),
      );
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now();
      await prefs.setString(lastBackupKey, now.toUtc().toIso8601String());
      if (!mounted) return;
      setState(() => _lastExport = now);
      _notice(l10n.dataBackupExportDone(backup.values.length));
    } catch (_) {
      _notice(l10n.dataBackupExportFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    if (_busy) return;
    final l10n = context.l10n;
    setState(() => _busy = true);
    try {
      final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['json']);
      final path = picked.firstOrNull?.path;
      if (path == null) return;
      final AppBackup backup;
      try {
        backup = await readBackupFile(File(path));
      } on BackupFormatException {
        _notice(l10n.dataBackupRestoreFailed);
        return;
      }
      if (!mounted) return;
      final scopes = await _askScopes(backup);
      if (scopes == null || scopes.isEmpty || !mounted) return;
      final confirmed = await _confirm(backup, scopes);
      if (confirmed != true || !mounted) return;
      final report = await restoreBackup(backup, scopes: scopes);
      if (!mounted) return;
      setState(() => _restored = true);
      _notice(l10n.dataBackupRestoreDone(report.restored, report.skipped));
      unawaited(_load());
    } catch (_) {
      _notice(l10n.dataBackupRestoreFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<Set<BackupScope>?> _askScopes(AppBackup backup) {
    final l10n = context.l10n;
    final selected = {...backup.scopes};
    return showDialog<Set<BackupScope>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(l10n.dataBackupRestoreTitle),
          contentPadding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final scope in BackupScope.values)
                  if (backup.values.keys.any((key) => BackupScope.of(key) == scope))
                    CheckboxListTile(
                      key: ValueKey('restore-scope-${scope.name}'),
                      value: selected.contains(scope),
                      onChanged: (value) => setDialogState(() {
                        if (value ?? false) {
                          selected.add(scope);
                        } else {
                          selected.remove(scope);
                        }
                      }),
                      controlAffinity: ListTileControlAffinity.leading,
                      dense: true,
                      title: Text(_scopeLabel(l10n, scope)),
                      secondary: Text(
                        '${backup.values.keys.where((key) => BackupScope.of(key) == scope).length}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.commonCancel)),
            FilledButton(onPressed: () => Navigator.of(context).pop(selected), child: Text(l10n.commonDone)),
          ],
        ),
      ),
    );
  }

  Future<bool?> _confirm(AppBackup backup, Set<BackupScope> scopes) {
    final l10n = context.l10n;
    final count = backup.values.keys.where((key) => scopes.contains(BackupScope.of(key))).length;
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.dataBackupConfirmTitle),
        content: Text(l10n.dataBackupConfirmBody(count)),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(l10n.commonCancel)),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(l10n.dataBackupRestore)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AppPage.list(
      title: l10n.dataBackupTitle,
      children: [
        if (_restored)
          SettingsSection(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(AppIcons.refresh, size: 20, color: DshColors.of(context).textTertiary),
                    const SizedBox(width: 12),
                    Expanded(child: Text(l10n.dataBackupRestartHint)),
                  ],
                ),
              ),
            ],
          ),
        SettingsSection(
          title: l10n.dataBackupScopeTitle,
          children: [
            for (final scope in BackupScope.values)
              CheckboxListTile(
                key: ValueKey('backup-scope-${scope.name}'),
                value: _selected.contains(scope),
                onChanged: _busy
                    ? null
                    : (value) => setState(() {
                        if (value ?? false) {
                          _selected.add(scope);
                        } else {
                          _selected.remove(scope);
                        }
                      }),
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
                title: Text(_scopeLabel(l10n, scope)),
                secondary: Text(
                  l10n.dataBackupCount(_counts[scope] ?? 0),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
          footer: Text(l10n.dataBackupScopeHint),
        ),
        SettingsSection(
          children: [
            SettingsTile(
              icon: AppIcons.archive,
              spot: Spots.dataBackupExport,
              title: l10n.dataBackupExport,
              subtitle: l10n.dataBackupExportHint,
              onTap: _busy ? null : () => unawaited(_export()),
            ),
            SettingsTile(
              icon: AppIcons.refresh,
              spot: Spots.dataBackupRestore,
              title: l10n.dataBackupRestore,
              subtitle: l10n.dataBackupRestoreHint,
              onTap: _busy ? null : () => unawaited(_restore()),
            ),
          ],
          footer: Text(
            _lastExport == null ? l10n.dataBackupNeverExported : l10n.dataBackupLastExport(_formatWhen(_lastExport!)),
          ),
        ),
      ],
    );
  }
}

String _formatWhen(DateTime at) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${at.year}-${two(at.month)}-${two(at.day)} ${two(at.hour)}:${two(at.minute)}';
}
