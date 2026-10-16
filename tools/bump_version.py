#!/usr/bin/env python3
"""
bump_version.py — 学聚 App 一键改版本号
========================================

为什么需要这个脚本：
  * App 版本号出现在两处：
      - lib/core/constants.dart 里的 `kAppVersion`
      - pubspec.yaml 里的 `version: X.Y.Z+N`
  * 任何一处漏改，要么「设置 → 关于」显示旧版号，要么
    Release 标签跟实际代码对不上、用户装包会困惑。
  * 用户是小白，手改两处容易漏，所以这个脚本帮你一次同步。

用法：
  1. 装 Python 3.10+（项目已经用 3.13）
  2. 在 studyhub_app/ 根目录跑：
       python tools/bump_version.py 1.10.0
     （默认 build 号自动 +1，不够可以自己指定：python tools/bump_version.py 1.10.0 17）

  3. 跑完会打印：

       ✓ pubspec.yaml : version: 1.7.0+14 → 1.10.0+17
       ✓ constants.dart: kAppVersion  = '1.7.0' → '1.10.0'
       ⚠️ 记得手动跑：flutter pub get
       ⚠️ 记得在设置页 README 里加版本变更说明

  4. 检查 git diff，commit + push → 触发云端 CI

CI 怎么发现版本不一致（v1.9.0 引入）：
  lib/main.dart 启动时会断言 kAppVersion == pubspecVersion 去掉 +N 的部分。
  不一致时：
    - Debug 模式：assert 抛异常，App 闪退（强提醒）
    - Release 模式：控制台 print 红字，并在设置页「关于」卡片顶部加红条
"""
import re
import sys
import pathlib

REPO = pathlib.Path(__file__).resolve().parent.parent
PUBSPEC = REPO / 'pubspec.yaml'
CONSTANTS = REPO / 'lib' / 'core' / 'constants.dart'

RE_VERSION = re.compile(r'^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)\s*$', re.M)
RE_KAPP = re.compile(r"const String kAppVersion = '(\d+\.\d+\.\d+)';")
# v1.9.0+17 修：以前只改 kAppVersion 不改 kPubspecVersion，
# 启动时 assert kAppVersion == kPubspecVersion 去掉 +N 的部分会失败。
RE_KPUB = re.compile(r"const String kPubspecVersion = '(\d+\.\d+\.\d+)\+(\d+)';")


def die(msg):
    print(f'❌ {msg}', file=sys.stderr)
    sys.exit(1)


def bump(version: str, build: int | None) -> tuple[str, str, str, int, str, str, str]:
    """返回 (pubspec_version, kapp_version, old_pubspec, new_pubspec, kpub_old, kpub_new, kapp_old)"""
    m = re.match(r'^(\d+)\.(\d+)\.(\d+)$', version)
    if not m:
        die(f'版本号格式不对：{version}（应该是 X.Y.Z，比如 1.10.0）')

    pubspec = PUBSPEC.read_text(encoding='utf-8')
    m_old = RE_VERSION.search(pubspec)
    if not m_old:
        die('pubspec.yaml 找不到 `version: X.Y.Z+N` 这一行')

    old_v = m_old.group(0)  # 整行 `version: 1.7.0+14`
    old_build = int(m_old.group(4))
    new_build = build if build is not None else old_build + 1
    new_v = f'version: {m.group(0)}+{new_build}'

    consts = CONSTANTS.read_text(encoding='utf-8')
    m_k = RE_KAPP.search(consts)
    if not m_k:
        die('constants.dart 找不到 `kAppVersion = ...` 这一行')
    old_kapp = m_k.group(0)
    new_kapp = f"const String kAppVersion = '{m.group(0)}';"

    # kPubspecVersion 也同步（否则启动会 assert 失败）
    m_kp = RE_KPUB.search(consts)
    if not m_kp:
        # 旧版（v1.9.0 之前）只有 kAppVersion，没有 kPubspecVersion，跳过不报错
        old_kpub = None
        new_kpub = None
    else:
        old_kpub = m_kp.group(0)
        new_kpub = f"const String kPubspecVersion = '{m.group(0)}+{new_build}';"

    return new_v, new_kapp, old_v, old_kapp, old_kpub, new_kpub, m.group(0)


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ('-h', '--help'):
        print(__doc__)
        sys.exit(0)

    version = sys.argv[1]
    build = int(sys.argv[2]) if len(sys.argv) > 2 else None

    new_v, new_kapp, old_v, old_kapp, old_kpub, new_kpub, _ = bump(version, build)

    # 写
    pubspec = PUBSPEC.read_text(encoding='utf-8')
    pubspec = pubspec.replace(old_v, new_v)
    PUBSPEC.write_text(pubspec, encoding='utf-8')

    consts = CONSTANTS.read_text(encoding='utf-8')
    consts = consts.replace(old_kapp, new_kapp)
    if old_kpub is not None and new_kpub is not None:
        consts = consts.replace(old_kpub, new_kpub)
    CONSTANTS.write_text(consts, encoding='utf-8')

    print(f'✓ pubspec.yaml  : {old_v:>22s} → {new_v}')
    print(f"✓ constants.dart: {old_kapp.split(' = ')[1].rstrip(';')} → {new_kapp.split(' = ')[1]}")
    if old_kpub is not None:
        print(f"✓ constants.dart: {old_kpub.split(' = ')[1].rstrip(';')} → {new_kpub.split(' = ')[1]}")
    print()
    print('接下来要做：')
    print('  1. cd studyhub_app && flutter pub get')
    print('  2. 在 lib/ui/home/settings_page.dart 的「关于」卡片里加新版本变更说明')
    print('  3. git add -A && git commit -m "v1.10.0 改版本号" && git push')
    print('  4. 等 CI 出 APK，新版本号会在「设置 → 关于」里出现')


if __name__ == '__main__':
    main()
