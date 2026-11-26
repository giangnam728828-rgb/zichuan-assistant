// 备份与恢复：把本机偏好里的用户数据按范围打成一个 JSON 文件，交给系统
// 分享面板；恢复时按同一范围写回。
//
// 密钥不进备份：API key、token、口令一类（[isSecretKey]）在导出和恢复两侧
// 都会被跳过。范围只决定导哪些、写哪些；写入按值类型进行，坏条目跳过，
// 不会把一份不完整的文件写成空设置。

import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// 一个可勾选的备份范围。范围只影响"导哪些键、写哪些键"，不改变值的类型。
enum BackupScope {
  chat,
  appearance,
  voice,
  notify,
  models,
  plugins,
  remote,
  other;

  /// [key] 属于哪个范围。按前缀判定；认不出的进 [other]，仍然可以单独勾选。
  static BackupScope of(String key) {
    final k = key.toLowerCase();
    for (final scope in values) {
      if (scope == other) continue;
      if (_prefixes[scope]!.any(k.startsWith)) return scope;
    }
    return other;
  }

  static const _prefixes = <BackupScope, List<String>>{
    chat: [
      'chat',
      'draft',
      'composer',
      'session',
      'conversation',
      'read_list',
      'read-list',
      'star_prompt',
      'table_tint',
      'last_session',
      'new_chat',
      'quote',
      'mention',
    ],
    appearance: [
      'appearance',
      'theme',
      'wallpaper',
      'tile',
      'font',
      'icon',
      'launch',
      'pet',
      'ui.',
      'layout',
      'quick_panel',
      'accent',
      'app_language',
      'locale',
      'screen',
    ],
    voice: ['voice', 'speech', 'asr', 'tts', 'companion', 'call'],
    notify: ['notify', 'notification', 'schedule', 'alarm', 'live_activity', 'reminder', 'attention'],
    models: [
      'model',
      'provider',
      'engine',
      'balance',
      'usage',
      'preset',
      'agent',
      'subagent',
      'skill',
      'media.',
      'web_search',
      'shell',
      'runtime',
    ],
    plugins: ['plugin', 'workshop', 'tavern', 'market', 'forum', 'bots', 'cordis', 'localenv'],
    remote: ['host', 'remote', 'ssh', 'relay', 'p2p', 'pair', 'tunnel', 'workspace', 'active_host'],
  };
}

/// 是否是一把钥匙：API key、token、口令、凭据。命中就不进备份，也不写回。
///
/// 误判只会少备份一个标记（例如 `onboarding_key_skipped`），不会泄露东西；
/// 漏判会让密钥躺进用户随手分享的文件里，所以宁可宽一点。
bool isSecretKey(String key) {
  final k = key.toLowerCase();
  return k.contains('api_key') ||
      k.contains('apikey') ||
      k.contains('api-key') ||
      k.contains('token') ||
      k.contains('secret') ||
      k.contains('password') ||
      k.contains('credential') ||
      k.contains('_key') ||
      k.startsWith('key');
}

/// 上次导出时间：由页面写，用来在页脚说"上次备份"。
const lastBackupKey = 'data_backup.last_export_at';

/// 备份文件的格式标记；[AppBackup.decode] 只认这个。
const _format = 'zichuan-app-backup';

/// 当前格式版本。改结构时加一，旧文件在 [AppBackup.decode] 里被拒绝。
const _schema = 1;

/// 一份备份：导出时收集的键值，或从文件读回的一份。
class AppBackup {
  AppBackup({required this.createdAt, required this.appVersion, required Map<String, Object?> values})
    : values = Map.unmodifiable(values);

  final DateTime createdAt;
  final String appVersion;

  /// 偏好键 → 值；只含 [BackupScope] 认得的值类型（String / num / bool /
  /// List<String>），密钥在构造前已被过滤。
  final Map<String, Object?> values;

  /// 这份备份实际覆盖的范围。
  Set<BackupScope> get scopes => {for (final key in values.keys) BackupScope.of(key)};

  Map<String, Object?> toJson() => {
    'format': _format,
    'schema': _schema,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'appVersion': appVersion,
    'scopes': [for (final scope in scopes) scope.name],
    'values': values,
  };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// 读一份备份文件的内容。格式不对、版本不认识、值不是偏好支持的类型，
  /// 都抛 [BackupFormatException]；类型不对的单条会被跳过，不拖垮整份文件。
  static AppBackup decode(String text) {
    final Object? raw;
    try {
      raw = jsonDecode(text);
    } on FormatException {
      throw const BackupFormatException('not json');
    }
    if (raw is! Map) throw const BackupFormatException('root is not an object');
    if (raw['format'] != _format) throw const BackupFormatException('not a backup file');
    if (raw['schema'] != _schema) throw const BackupFormatException('unsupported schema');
    final values = raw['values'];
    if (values is! Map) throw const BackupFormatException('values missing');

    final clean = <String, Object?>{};
    for (final entry in values.entries) {
      final key = entry.key;
      if (key is! String || key.isEmpty || isSecretKey(key)) continue;
      final value = entry.value;
      if (value is String || value is num || value is bool) {
        clean[key] = value;
      } else if (value is List && value.every((item) => item is String)) {
        clean[key] = List<String>.from(value);
      }
    }
    return AppBackup(
      createdAt: DateTime.tryParse(raw['createdAt'] as String? ?? '')?.toLocal() ?? DateTime.now(),
      appVersion: raw['appVersion'] as String? ?? '',
      values: clean,
    );
  }
}

/// 备份文件读不进来。
class BackupFormatException implements Exception {
  const BackupFormatException(this.reason);

  final String reason;

  @override
  String toString() => 'BackupFormatException: $reason';
}

/// 恢复的结果：写进去几条，跳过几条（类型不符或密钥）。
class RestoreReport {
  const RestoreReport({required this.restored, required this.skipped});

  final int restored;
  final int skipped;
}

/// 按 [scopes] 收集本机偏好，生成一份备份。
Future<AppBackup> collectBackup({required Set<BackupScope> scopes, required String appVersion}) async {
  final prefs = await SharedPreferences.getInstance();
  final values = <String, Object?>{};
  for (final key in prefs.getKeys()) {
    if (isSecretKey(key)) continue;
    if (!scopes.contains(BackupScope.of(key))) continue;
    final value = prefs.get(key);
    if (value == null) continue;
    if (value is String || value is num || value is bool) {
      values[key] = value;
    } else if (value is List && value.every((item) => item is String)) {
      values[key] = List<String>.from(value);
    }
  }
  return AppBackup(createdAt: DateTime.now(), appVersion: appVersion, values: values);
}

/// 每个范围现在有多少条可备份的键；页面用它显示数量，空范围可以一眼看出。
Future<Map<BackupScope, int>> countBackupEntries() async {
  final prefs = await SharedPreferences.getInstance();
  final counts = {for (final scope in BackupScope.values) scope: 0};
  for (final key in prefs.getKeys()) {
    if (isSecretKey(key) || prefs.get(key) == null) continue;
    counts[BackupScope.of(key)] = counts[BackupScope.of(key)]! + 1;
  }
  return counts;
}

/// 文件名按导出时间：`zichuan-backup-20261126-1841.json`。
String backupFileName(DateTime at) {
  String two(int n) => n.toString().padLeft(2, '0');
  return 'zichuan-backup-${at.year}${two(at.month)}${two(at.day)}-${two(at.hour)}${two(at.minute)}.json';
}

/// 写到 [dir] 下，返回文件。调用方负责分享或清理。
Future<File> writeBackupFile(AppBackup backup, {required Directory dir}) async {
  final file = File('${dir.path}/${backupFileName(backup.createdAt)}');
  await file.writeAsString(backup.encode(), flush: true);
  return file;
}

/// 读 [file]；超过 16 MB 直接拒绝（偏好数据不会有这么大，防呆）。
Future<AppBackup> readBackupFile(File file) async {
  if (await file.length() > 16 * 1024 * 1024) {
    throw const BackupFormatException('file too large');
  }
  return AppBackup.decode(await file.readAsString());
}

/// 把 [backup] 里属于 [scopes] 的条目写回本机偏好。
///
/// 只写值类型对得上的条目；密钥一律跳过。写入后当前进程里的 provider 仍是
/// 旧值，页面据此提示重启。
Future<RestoreReport> restoreBackup(AppBackup backup, {required Set<BackupScope> scopes}) async {
  final prefs = await SharedPreferences.getInstance();
  var restored = 0;
  var skipped = 0;
  for (final entry in backup.values.entries) {
    if (!scopes.contains(BackupScope.of(entry.key)) || isSecretKey(entry.key)) {
      skipped++;
      continue;
    }
    final value = entry.value;
    final bool ok;
    if (value is bool) {
      ok = await prefs.setBool(entry.key, value);
    } else if (value is int) {
      ok = await prefs.setInt(entry.key, value);
    } else if (value is double) {
      ok = await prefs.setDouble(entry.key, value);
    } else if (value is String) {
      ok = await prefs.setString(entry.key, value);
    } else if (value is List<String>) {
      ok = await prefs.setStringList(entry.key, value);
    } else {
      skipped++;
      continue;
    }
    if (ok) {
      restored++;
    } else {
      skipped++;
    }
  }
  return RestoreReport(restored: restored, skipped: skipped);
}
