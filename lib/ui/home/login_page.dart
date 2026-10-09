import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../data/local/settings_store.dart';
import '../../data/models/models.dart';
import '../../providers/providers.dart';
import 'server_guide_page.dart';

/// WebDAV 登录页
class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _alias = TextEditingController(text: '我的服务器');
  final _url = TextEditingController();
  final _user = TextEditingController();
  final _pwd = TextEditingController();
  final _root = TextEditingController(text: AppDirs.defaultRoot);

  bool _obscure = true;
  bool _busy = false;
  String? _msg;
  bool _ok = false;

  /// 用过的服务器地址（不含用户名密码）
  List<DavAccount> _history = const [];

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  /// 预填上次用过的服务器地址；用户名和密码一律留空，由用户自己填
  Future<void> _loadHistory() async {
    final list = await SettingsStore.instance.recentServers();
    if (!mounted) return;
    setState(() => _history = list);
    if (list.isNotEmpty && _url.text.trim().isEmpty) {
      final first = list.first;
      _alias.text = first.alias.isEmpty ? '我的服务器' : first.alias;
      _url.text = first.baseUrl;
      _root.text = first.root;
    }
  }

  void _showHistory() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 6),
              child: Text('用过的服务器地址', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            for (final s in _history)
              ListTile(
                leading: const Icon(Icons.dns_outlined),
                title: Text(s.alias.isEmpty ? s.baseUrl : s.alias),
                subtitle: Text('${s.baseUrl}\n根目录 ${s.root}', style: const TextStyle(fontSize: 11.5)),
                isThreeLine: true,
                onTap: () {
                  Navigator.pop(context);
                  setState(() {
                    _alias.text = s.alias.isEmpty ? '我的服务器' : s.alias;
                    _url.text = s.baseUrl;
                    _root.text = s.root;
                    // 用户名 / 密码保持为空
                    _user.clear();
                    _pwd.clear();
                  });
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _alias.dispose();
    _url.dispose();
    _user.dispose();
    _pwd.dispose();
    _root.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    if (_url.text.trim().isEmpty) {
      setState(() {
        _ok = false;
        _msg = '请先填写服务器地址';
      });
      return;
    }
    setState(() {
      _busy = true;
      _msg = null;
    });
    final acc = DavAccount(
      alias: _alias.text.trim().isEmpty ? '我的服务器' : _alias.text.trim(),
      baseUrl: _url.text.trim(),
      username: _user.text.trim(),
      password: _pwd.text,
      root: _normalizeRoot(_root.text),
    );
    final check = await ref.read(accountProvider.notifier).login(acc);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _ok = check.ok;
      _msg = check.ok
          ? '连接成功：读到 ${check.fileCount} 个条目。${check.message}'
          : check.message;
    });
    if (check.ok) {
      // 给用户一眼看清结果，1.2 秒后自动返回首页
      await Future.delayed(const Duration(milliseconds: 1200));
      if (mounted) Navigator.of(context).pop(true);
    }
  }

  String _normalizeRoot(String s) {
    var v = s.trim();
    if (v.isEmpty) return AppDirs.defaultRoot;
    if (!v.startsWith('/')) v = '/$v';
    while (v.length > 1 && v.endsWith('/')) {
      v = v.substring(0, v.length - 1);
    }
    return v;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('连接 WebDAV 服务器'),
        actions: [
          if (_history.isNotEmpty)
            IconButton(
              tooltip: '用过的服务器地址',
              icon: const Icon(Icons.history),
              onPressed: _showHistory,
            ),
          TextButton.icon(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ServerGuidePage())),
            icon: const Icon(Icons.folder_open, size: 18),
            label: const Text('目录规范'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          TextField(
            controller: _alias,
            decoration: const InputDecoration(labelText: '给它起个名（只用于显示）', prefixIcon: Icon(Icons.badge_outlined)),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: '服务器地址',
              hintText: '如 http://192.168.1.10:5005/ 或 https://xxx.synology.me:5006/',
              prefixIcon: Icon(Icons.dns_outlined),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _user,
            decoration: const InputDecoration(labelText: '用户名', prefixIcon: Icon(Icons.person_outline)),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _pwd,
            obscureText: _obscure,
            decoration: InputDecoration(
              labelText: '密码（建议用应用专用密码）',
              prefixIcon: const Icon(Icons.key_outlined),
              suffixIcon: IconButton(
                icon: Icon(_obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _root,
            decoration: const InputDecoration(
              labelText: '资料根目录',
              helperText: '默认 /StudyHub，改成你自己的也可以',
              prefixIcon: Icon(Icons.folder_outlined),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _busy ? null : _test,
            icon: _busy
                ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.wifi_tethering),
            label: Text(_busy ? '正在连接…' : '测试连接并登录'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _busy ? null : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ServerGuidePage())),
            icon: const Icon(Icons.help_outline, size: 18),
            label: const Text('服务器上该建哪些目录？'),
          ),
          if (_msg != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: (_ok ? scheme.primaryContainer : scheme.errorContainer).withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(_ok ? Icons.check_circle_outline : Icons.error_outline,
                      size: 18, color: _ok ? scheme.primary : scheme.error),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_msg!, style: const TextStyle(fontSize: 13, height: 1.5))),
                ],
              ),
            ),
          ],
          const SizedBox(height: 20),
          Text(
            '常见填法\n'
            '· 群晖：控制面板开启 WebDAV Server 后，地址是 http://群晖IP:5005/\n'
            '· chfs：http://电脑IP:端口/（在设置里打开 WebDAV）\n'
            '· 地址结尾带斜杠 / 更稳妥；HTTPS 自签证书报错时改用 http',
            style: TextStyle(fontSize: 12.5, height: 1.7, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
