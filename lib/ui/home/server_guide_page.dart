import 'package:flutter/material.dart';

import '../../core/constants.dart';

/// 服务器目录规范说明页：告诉用户「服务器上该怎么建目录」
class ServerGuidePage extends StatelessWidget {
  const ServerGuidePage({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('服务器目录规范')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: scheme.primaryContainer.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('照着建一次，以后只往里丢文件就行', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Text(
                  '在你自己的 WebDAV 服务器根目录下建一个 StudyHub 文件夹，然后在里面建下面 6 个子文件夹。'
                  'App 只认这 6 个目录，名称必须一模一样（区分大小写）。',
                  style: text.bodyMedium,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _TreeCard(),
          const SizedBox(height: 16),
          Text('每个目录做什么用', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          ...AppDirs.all.map((d) => _DirTile(dir: d)),
          const SizedBox(height: 16),
          Text('每个目录支持哪些格式', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(
            '下面的清单直接读 App 内置的判定表，改代码就会跟着变，不会过时。'
            '放错目录一般也能看，但分门别类放体验最好。',
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          _FormatCard(),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.lightbulb_outline, size: 18, color: scheme.primary),
                      const SizedBox(width: 8),
                      Text('几个要点', style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  const _Bullet('笔记配图跟 .md 文件放同一个目录，markdown 里直接写 ![](图片名.png) 即可。'),
                  const _Bullet('题库：一个 .json 就是一套题库。同一个目录里放多个 json（第一章、第二章…），进目录就能看到每套的进度。'),
                  const _Bullet('下载站：想在手机上下载的文件扔进 download/，工具页最上面那个按钮直接进，点一下就能下。'),
                  const _Bullet('html 小工具：tools/ 里一个子文件夹一个分类，根目录下散放的 .html 单独归到「独立小工具」。'),
                  const _Bullet('没有的目录不影响使用，App 会提示缺少哪些，你在服务器上补建即可。'),
                  const _Bullet('目录想改名、加子分类都随意，App 每次打开都会重新读服务器结构。'),
                  const _Bullet('群晖（WebDAV Server）读写与拖进度都完整；chfs 等工具的部分版本目录遍历不全，App 会自动降级处理。'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.lock_outline, size: 18, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '隐私说明：账号密码只加密保存在这台手机上，App 只连接你自己的服务器，不会把任何内容上传到第三方。',
                      style: text.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TreeCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SelectableText(
            '/\n'
            '└─ StudyHub/\n'
            '   ├─ notes/     笔记\n'
            '   │   ├─ 中医/    经络知识.md\n'
            '   │   └─ 绳结/    平结.md、演示.gif\n'
            '   ├─ media/     视频与图片\n'
            '   │   ├─ 教学视频/\n'
            '   │   └─ 图片/\n'
            '   ├─ quiz/      题库（一个 .json 一套）\n'
            '   │   └─ python基础/\n'
            '   │       ├─ 第一章.json\n'
            '   │       └─ 第二章.json\n'
            '   ├─ tools/     消杀计算器等html小工具\n'
            '   │   ├─ 换算/      子文件夹=分类\n'
            '   │   └─ 公式.html  放根目录=独立小工具\n'
            '   ├─ download/  下载站（要下载的文件）\n'
            '   │   ├─ 课件/讲义.pdf\n'
            '   │   └─ 软件/xxx.apk\n'
            '   └─ backup/    错题本、笔记备份（App自写）',
            style: TextStyle(fontFamily: 'monospace', fontSize: 12.5, height: 1.65),
          ),
        ],
      ),
    );
  }
}

/// 「每个目录支持哪些格式」卡片（v1.8.0 需求2）。
///
/// 清单**不写死**：视频/音频/图片/文档四类是直接读 [FileTypes] 的常量集合，
/// 以后往 FileTypes 里加后缀，这一页自动跟着更新，不会变成过期文档。
class _FormatCard extends StatelessWidget {
  const _FormatCard();

  static String _join(Set<String> s) {
    final list = s.toList()..sort();
    return list.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rows = <(String, String, String, String)>[
      // (目录, 图标, 类型, 后缀清单)
      (AppDirs.notes, '笔记正文', 'md', '一篇 .md 就是一篇笔记'),
      (AppDirs.media, '视频', _join(FileTypes.video), '点开就是内置播放器，支持全屏 / 倍速 / 进度记忆'),
      (AppDirs.media, '音频', _join(FileTypes.audio), '同一个播放器，封面按文件名匹配'),
      (AppDirs.media, '图片', _join(FileTypes.image), '相册里左右翻；笔记里也能直接引用'),
      (AppDirs.quiz, '题库', 'json', '一个 .json 一套题，字段见下面的说明'),
      (AppDirs.notes, '文档', 'pdf · epub', 'pdf 内置阅读器；epub 走电子书模式'),
      (AppDirs.tools, 'html 小工具', 'html · htm', '一个子文件夹一个分类，入口文件名 index.html / main.html'),
      (AppDirs.download, '下载站', '不限', '想在手机上下载什么就放什么'),
      (AppDirs.backup, '备份', 'json · md', 'App 自动写，一般不用手动放'),
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) const Divider(height: 18),
              _FormatRow(
                dir: rows[i].$1,
                kind: rows[i].$2,
                exts: rows[i].$3,
                note: rows[i].$4,
                scheme: scheme,
              ),
            ],
            const Divider(height: 18),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.text_snippet_outlined, size: 16, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '可以直接在 App 里当文本读的还有：log · xml · yaml · yml · csv。'
                    '后缀不认识的文件会走系统「用其他应用打开」，不影响下载。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FormatRow extends StatelessWidget {
  final String dir;
  final String kind;
  final String exts;
  final String note;
  final ColorScheme scheme;

  const _FormatRow({
    required this.dir,
    required this.kind,
    required this.exts,
    required this.note,
    required this.scheme,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: scheme.primaryContainer.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(dir, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
            ),
            const SizedBox(width: 8),
            Text(kind, style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
          ],
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.only(left: 2),
          child: SelectableText(
            exts,
            style: TextStyle(fontFamily: 'monospace', fontSize: 11.5, height: 1.5, color: scheme.primary),
          ),
        ),
        const SizedBox(height: 2),
        Padding(
          padding: const EdgeInsets.only(left: 2),
          child: Text(note, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        ),
      ],
    );
  }
}

class _DirTile extends StatelessWidget {
  final String dir;
  const _DirTile({required this.dir});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 3),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: scheme.primaryContainer.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(6)),
            child: Text(dir, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(AppDirs.usage[dir] ?? '', style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: 2),
                Text('例如：${AppDirs.sample[dir] ?? ''}', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  final String text;
  const _Bullet(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(padding: EdgeInsets.only(top: 6, right: 8), child: Icon(Icons.circle, size: 5)),
          Expanded(child: Text(text, style: Theme.of(context).textTheme.bodySmall)),
        ],
      ),
    );
  }
}
