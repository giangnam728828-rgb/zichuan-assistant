// 备份与恢复的纯逻辑：范围归属、密钥过滤、文件往返、按范围写回。

import 'dart:convert';

import 'package:dsh_app/state/data_backup.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('scopes follow the key prefix', () {
    expect(BackupScope.of('chat_drafts_v1'), BackupScope.chat);
    expect(BackupScope.of('last_session_id'), BackupScope.chat);
    expect(BackupScope.of('appearance.preset'), BackupScope.appearance);
    expect(BackupScope.of('theme_mode'), BackupScope.appearance);
    expect(BackupScope.of('voice_recognition_mode'), BackupScope.voice);
    expect(BackupScope.of('notify_done'), BackupScope.notify);
    expect(BackupScope.of('model_defaults'), BackupScope.models);
    expect(BackupScope.of('workshop.pending.v1'), BackupScope.plugins);
    expect(BackupScope.of('remote_ssh_hosts'), BackupScope.remote);
    expect(BackupScope.of('active_host'), BackupScope.remote);
    expect(BackupScope.of('onboarding_welcome_seen'), BackupScope.other);
    expect(BackupScope.of('some_future_key'), BackupScope.other);
  });

  test('keys and credentials are never backed up', () {
    expect(isSecretKey('deepseek_api_key'), isTrue);
    expect(isSecretKey('provider.token'), isTrue);
    expect(isSecretKey('account_password'), isTrue);
    expect(isSecretKey('appearance.preset'), isFalse);
    expect(isSecretKey('chat_drafts_v1'), isFalse);
  });

  test('a backup round-trips, dropping secrets and unknown value types', () {
    final backup = AppBackup(
      createdAt: DateTime(2026, 11, 26, 18, 41),
      appVersion: '2.0.1+1',
      values: {
        'chat_drafts_v1': jsonEncode({
          'new': {'t': 'hi'},
        }),
        'theme_mode': 1,
        'notify_done': true,
        'voice_rate': 1.25,
        'quick_panel_items': ['a', 'b'],
      },
    );
    final encoded = backup.encode();
    final decoded = AppBackup.decode(encoded);

    expect(decoded.values, backup.values);
    expect(decoded.appVersion, '2.0.1+1');
    expect(decoded.createdAt, backup.createdAt);
    expect(decoded.scopes, containsAll([BackupScope.chat, BackupScope.appearance]));

    final withSecret = AppBackup(
      createdAt: DateTime(2026),
      appVersion: '1',
      values: {'deepseek_api_key': 'sk-x', 'chat_drafts_v1': '{}'},
    );
    expect(AppBackup.decode(withSecret.encode()).values, {'chat_drafts_v1': '{}'});
  });

  test('a file from another app or a newer schema is refused', () {
    expect(
      () => AppBackup.decode('{"format":"something-else","schema":1,"values":{}}'),
      throwsA(isA<BackupFormatException>()),
    );
    expect(
      () => AppBackup.decode('{"format":"zichuan-app-backup","schema":2,"values":{}}'),
      throwsA(isA<BackupFormatException>()),
    );
    expect(() => AppBackup.decode('not json'), throwsA(isA<BackupFormatException>()));
  });

  test('collect keeps the ticked scopes and skips credentials', () async {
    SharedPreferences.setMockInitialValues({
      'chat_drafts_v1': '{"new":{"t":"hi"}}',
      'theme_mode': 2,
      'remote_ssh_hosts': '[]',
      'deepseek_api_key': 'sk-secret',
    });

    final backup = await collectBackup(scopes: {BackupScope.chat, BackupScope.appearance}, appVersion: '2.0.1+1');

    expect(backup.values.keys, unorderedEquals(['chat_drafts_v1', 'theme_mode']));
    expect(backup.values.values, isNot(contains('sk-secret')));
  });

  test('restore writes only the ticked scopes and never a secret', () async {
    SharedPreferences.setMockInitialValues({'chat_drafts_v1': 'old', 'theme_mode': 0, 'remote_ssh_hosts': 'old'});
    final backup = AppBackup(
      createdAt: DateTime(2026),
      appVersion: '2.0.1+1',
      values: {'chat_drafts_v1': 'new', 'theme_mode': 2, 'remote_ssh_hosts': '[]', 'deepseek_api_key': 'sk-x'},
    );

    final report = await restoreBackup(backup, scopes: {BackupScope.chat});

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('chat_drafts_v1'), 'new');
    expect(prefs.getInt('theme_mode'), 0);
    expect(prefs.getString('remote_ssh_hosts'), 'old');
    expect(prefs.getString('deepseek_api_key'), isNull);
    expect(report.restored, 1);
    expect(report.skipped, greaterThan(0));
  });

  test('counts report what each scope holds', () async {
    SharedPreferences.setMockInitialValues({'chat_drafts_v1': '{}', 'theme_mode': 1, 'deepseek_api_key': 'sk-x'});

    final counts = await countBackupEntries();

    expect(counts[BackupScope.chat], 1);
    expect(counts[BackupScope.appearance], 1);
    expect(counts[BackupScope.remote], 0);
  });
}
