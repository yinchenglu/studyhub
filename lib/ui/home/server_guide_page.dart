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
              color: scheme.primaryContainer.withOpacity(0.45),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('照着建一次，以后只往里丢文件就行', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Text(
                  '在你自己的 WebDAV 服务器根目录下建一个 StudyHub 文件夹，然后在里面建下面 5 个子文件夹。'
                  'App 只认这 5 个目录，名称必须一模一样（区分大小写）。',
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
                  const _Bullet('每个题库单独一个子目录，目录名就是 App 里显示的题库名。'),
                  const _Bullet('没有的目录不影响使用，App 会提示缺少哪些，你在服务器上补建即可。'),
                  const _Bullet('目录想改名、加子分类都随意，App 每次打开都会重新读服务器结构。'),
                  const _Bullet('群晖（WebDAV Server）读写与拖进度都完整；chfs 等工具的部分版本目录遍历不全，App 会自动降级处理。'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            color: scheme.surfaceContainerHighest.withOpacity(0.4),
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
        color: scheme.surfaceContainerHighest.withOpacity(0.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SelectableText(
            '/\n'
            '└─ StudyHub/\n'
            '   ├─ notes/     笔记\n'
            '   │   ├─ 中医/    人体穴位图.png、经络知识.md\n'
            '   │   └─ 绳结/    平结.md、平结演示.gif\n'
            '   ├─ media/     视频与图片\n'
            '   │   ├─ 教学视频/\n'
            '   │   └─ 图片/\n'
            '   ├─ quiz/      题库\n'
            '   │   ├─ python基础/python基础.json\n'
            '   │   ├─ 医学中级/医学中级.json\n'
            '   │   └─ 单词/英语四级核心词.json\n'
            '   ├─ tools/     词库、速查表\n'
            '   └─ backup/    错题本、笔记备份（App 自动写）',
            style: TextStyle(fontFamily: 'monospace', fontSize: 12.5, height: 1.65),
          ),
        ],
      ),
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
            decoration: BoxDecoration(color: scheme.primaryContainer.withOpacity(0.6), borderRadius: BorderRadius.circular(6)),
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
