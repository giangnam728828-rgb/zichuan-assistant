// 「这一句话到底要什么」——议会与团队共用的意图判定（v4.3 · P0-A）。
//
// 背景：协作模式曾经无条件把父会话（普通聊天）里的历史资料塞进提示词，于是
// 用户在议会里说一句「你们好」，模型却拿着上一次的工程方案、仓库地址和 P0
// 结论作答，答得莫名其妙。
//
// 这里把「要不要读历史」变成一条可以单独测试的规则：
// - 只有**明确指代**（上面 / 前面 / 刚才 / 那个方案 / 继续 / 按前面的要求…）
//   才允许把父会话资料带进这一轮；
// - 问候、道谢、独立提问、分析当前消息里已经给出的内容，一律不带；
// - 什么算问候、什么算执行、什么算讨论，也都写在这里，页面与编排器只读结论，
//   不再各自散落一堆正则。
//
// 纯函数、无 Flutter、无 IO：`CollabContextPolicy` 与 `CollabIntent.of` 都能
// 在普通单元测试里直接断言。

/// 一条协作消息的意图。
enum CollabIntent {
  /// 问候、道谢、收到、在吗：只需要自然回应一句。
  social,

  /// 分析、讨论、咨询、评价：需要围绕当前问题给内容。
  discussion,

  /// 明确要求执行或交付（修复仓库、实现功能、构建、部署…）。
  execution,

  /// 只有标点/表情/半个字：不知道该干什么，先问清楚。
  clarification;

  /// 这一轮要不要按「任务」对待（拆分、派活、执行）。
  bool get isTask => this == CollabIntent.execution;

  /// 这一轮只需要自然对话，不需要长篇结构化输出。
  bool get isSocial => this == CollabIntent.social || this == CollabIntent.clarification;
}

/// 意图判定：规则集中在这里，页面与编排器只调用它。
abstract final class CollabIntentRules {
  /// 明确「指向此前内容」的说法。命中才允许读取父会话历史。
  static const referenceMarkers = <String>[
    '上面',
    '上述',
    '前述',
    '前面',
    '之前',
    '刚才',
    '刚刚',
    '上次',
    '上一轮',
    '上轮',
    '上一条',
    '那个方案',
    '那份方案',
    '那段方案',
    '那个仓库',
    '那个分支',
    '那个要求',
    '那些要求',
    '那条消息',
    '引用',
    '消息编号',
    '按这个办',
    '按那个办',
    '照旧',
    '沿用',
    '原方案',
    '原要求',
    '原任务',
    '继续',
    '接着',
    '接着做',
    '接着干',
    'as before',
    'same as above',
    'continue',
  ];

  /// 明确的执行动作。
  static const executionVerbs = <String>[
    '修复',
    '修好',
    '实现',
    '开发',
    '重构',
    '部署',
    '提交',
    '推送',
    '合并',
    '打包',
    '构建',
    '编译',
    '安装',
    '配置',
    '升级',
    '迁移',
    '接入',
    '补齐',
    '完成',
    '执行',
    '检查',
    '排查',
    '定位',
    '改',
    '写',
    '加',
    '删',
    '创建',
    '新建',
    '替换',
    '优化',
    '调整',
    '测试',
    '回归',
    '验证',
    '发布',
    '上线',
    '拉取',
    '克隆',
    '调研',
    '整理',
    '梳理',
    '补充',
    '生成',
    '输出',
    '导出',
    '导入',
    '翻译',
    '画',
    '清理',
    '重命名',
    '拆分',
    '标注',
    '处理',
    '跑',
    'clone',
    'fix',
    'implement',
    'refactor',
    'deploy',
    'build',
  ];

  /// 执行动作的落点。只有「动作 + 落点」同时出现才算执行任务：
  /// 「看看这个设计怎么样」有动作没落点，是讨论而不是派活。
  static const executionObjects = <String>[
    '仓库',
    '代码',
    '分支',
    '项目',
    '工程',
    '文件',
    '功能',
    '接口',
    '页面',
    '测试',
    'apk',
    '构建',
    '版本',
    'bug',
    '问题',
    '脚本',
    '组件',
    '模块',
    '依赖',
    '数据库',
    '服务',
    '任务',
    'repo',
    'branch',
    'pr',
    'commit',
  ];

  /// 讨论/咨询/评价的标志词：出现它就不再是「派活」。
  static const discussionMarkers = <String>[
    '分析',
    '怎么样',
    '如何',
    '怎么',
    '怎样',
    '咋',
    '为什么',
    '是什么',
    '什么',
    '哪些',
    '能不能',
    '是否',
    '评价',
    '看法',
    '建议',
    '讨论',
    '介绍',
    '解释',
    '对比',
    '优劣',
    '区别',
    '擅长',
    '能干',
    '会什么',
    '有什么用',
    '值不值',
    '好不好',
    '可以吗',
    '吗？',
    '吗?',
    '呢？',
    '呢?',
  ];

  /// 只算社交寒暄的词。整句由这些词（加语气词）拼成，才算社交。
  static const socialTokens = <String>[
    '你好',
    '您好',
    '你们好',
    '大家好',
    '各位好',
    '嗨',
    '哈喽',
    '哈啰',
    'hi',
    'hello',
    '在吗',
    '在么',
    '在不在',
    '都在吗',
    '你们都在吗',
    '早',
    '早安',
    '早上好',
    '上午好',
    '中午好',
    '下午好',
    '晚上好',
    '晚安',
    '谢谢',
    '多谢',
    '感谢',
    '辛苦了',
    '辛苦',
    '收到',
    '好的',
    '好',
    'ok',
    'okay',
    '嗯',
    '嗯嗯',
    '明白',
    '了解',
    '知道了',
    '再见',
    '拜拜',
    '太好了',
    '棒',
    '厉害',
  ];

  /// 语气词/称呼/标点：判定前先剥掉，不参与匹配。
  static const _fillers = <String>[
    '你们',
    '您',
    '你',
    '大家',
    '各位',
    '诸位',
    '呀',
    '啊',
    '哦',
    '啦',
    '呢',
    '吧',
    '哈',
    '嘛',
    '哟',
    '唉',
    '诶',
    '欸',
    '了',
    '的',
  ];

  static final _punctuation = RegExp(r'[\s\p{P}\p{S}]', unicode: true);

  /// 去掉空白、标点、符号、emoji，统一小写：只留下可比较的字。
  static String normalize(String text) => text.toLowerCase().replaceAll(_punctuation, '');

  /// 这一句是不是纯寒暄/客套。
  ///
  /// 判定是「整句都由寒暄词拼成」：`你好`、`你们好呀`、`在吗？`、`谢谢，辛苦了`
  /// 都算；`你好，帮我修复这个仓库` 因为后半句拼不出来，不算。
  static bool isSocial(String text) {
    var core = normalize(text);
    if (core.isEmpty) return false;
    for (final filler in _fillers) {
      core = core.replaceAll(filler, '');
    }
    if (core.isEmpty) return false;
    // 长句不可能是寒暄（避免把「你好，我想问一个复杂的问题…」误判）。
    if (core.length > 24) return false;
    var rest = core;
    var matched = 0;
    while (rest.isNotEmpty) {
      final token = _longestPrefix(rest, socialTokens);
      if (token == null) return false;
      rest = rest.substring(token.length);
      matched++;
      if (matched > 6) return false;
    }
    return true;
  }

  /// 文本里有没有明确指代此前内容的说法。
  static bool hasReference(String text) {
    final core = normalize(text);
    if (core.isEmpty) return false;
    for (final marker in referenceMarkers) {
      if (core.contains(normalize(marker))) return true;
    }
    // 「消息 #12」「资料 3」「第 2 条」这类编号引用。
    if (RegExp(r'#\d+').hasMatch(core)) return true;
    if (RegExp(r'(资料|消息|第)\d+').hasMatch(core)) return true;
    return false;
  }

  /// 判定意图。
  static CollabIntent of(String text) {
    final raw = text.trim();
    if (raw.isEmpty) return CollabIntent.clarification;
    if (isSocial(raw)) return CollabIntent.social;
    final core = normalize(raw);
    // 只有标点/表情/一两个字且不是寒暄：先问清楚要做什么。
    if (core.length <= 1) return CollabIntent.clarification;
    if (_looksLikeExecution(core)) return CollabIntent.execution;
    return CollabIntent.discussion;
  }

  static bool _looksLikeExecution(String core) {
    final verb = _firstMatch(core, executionVerbs);
    final discuss = _firstMatch(core, discussionMarkers);
    final object = _firstMatch(core, executionObjects);
    // 明确落点 + 动作：直接算执行（哪怕句尾有个「吗」）。
    if (verb != null && object != null) return true;
    // 只有动作、没有任何讨论标志：「调研并写一页」这类也是派活。
    // 讨论标志（分析/怎么样/为什么/）优先，避免把「看看这个设计怎么样」
    // 当成任务。
    if (verb != null && discuss == null) return true;
    // 「继续上一轮任务」「按前面的要求执行」：指代 + 继续/执行 = 接着干活。
    if (hasReference(core) &&
        _firstMatch(core, const ['继续', '接着', '执行', '照做', '按照']) != null &&
        discuss == null) {
      return true;
    }
    return false;
  }

  static String? _firstMatch(String core, List<String> needles) {
    for (final needle in needles) {
      if (core.contains(normalize(needle))) return needle;
    }
    return null;
  }

  /// [text] 以 [candidates] 里的哪一个开头（取最长）。
  static String? _longestPrefix(String text, List<String> candidates) {
    String? best;
    for (final candidate in candidates) {
      if (!text.startsWith(candidate)) continue;
      if (best == null || candidate.length > best.length) best = candidate;
    }
    return best;
  }
}

/// 上下文使用策略（v4.3 · P0-A · 2.3）。
///
/// 唯一入口：[allowsHistory]。返回 true 才允许构建父会话上下文包。
abstract final class CollabContextPolicy {
  /// 这一句是否允许自动带上父会话（普通聊天）的历史。
  ///
  /// 只有「明确指代此前内容」才允许；问候、道谢、独立提问、分析当前内容
  /// 一律不带——哪怕父会话里躺着一整份方案。
  static bool allowsHistory(String text) {
    final raw = text.trim();
    if (raw.isEmpty) return false;
    final intent = CollabIntentRules.of(raw);
    if (intent.isSocial) return false;
    return CollabIntentRules.hasReference(raw);
  }

  /// 给界面/日志看的一句话：为什么带/不带。
  static String explain(String text) {
    final raw = text.trim();
    if (raw.isEmpty) return '这句话是空的，不带历史';
    final intent = CollabIntentRules.of(raw);
    if (intent.isSocial) return '这是问候/寒暄，不带此前的资料';
    if (!CollabIntentRules.hasReference(raw)) return '没有指代此前内容，不带此前的资料';
    return '这句话明确指代了此前内容，带上对应资料';
  }

  /// 只保留允许的上下文：不允许就是空串（调用方不用再判一遍）。
  static String gate(String text, String context) {
    if (context.trim().isEmpty) return '';
    return allowsHistory(text) ? context : '';
  }
}
