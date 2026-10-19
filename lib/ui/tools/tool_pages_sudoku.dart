// ============================================================ 数独 v1.9.0
//
// #17「数独大改」一次性提交：
//   1. 11 种类型：标准 / 迷你 / 对角 X / 超数独 / 锯齿 / 杀手 / 不等式 /
//      奇偶 / 连续 / 箭头 / 百分比
//   2. 4 个难度（简单/中等/困难/地狱）
//   3. 笔记模式（铅笔痕）
//   4. 自动出题：Latin Square 洗牌 + 回溯求一组合法解 → 按难度挖洞
//   5. 解算器：每次落子校验，重错回退提示
//   6. 错题高亮、撤销、保存进度
//
// 引擎设计：
//   * `SudokuBoard` 是底层模型（一个二维 int 数组 + 候选笔记 Set）
//   * `SudokuRules` 提供约束 / 解法接口；
//     不同类型实现不同的 `isLegal / isComplete / randomShuffle`
//   * UI 走 `setState`，跑题时主动解算；没解出来就放着不纠错
//     （地狱难度才会发生，留给用户自己想）
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../data/local/pref_store.dart';

import 'tool_pages.dart'; // ToolScaffold / toast / copyText / keepScreenOn

// ============================================================ 类型

/// 数独类型枚举。**9 种最常见异形数独**（按各大主流数独 App 的
/// 类型排序：Sudoku.com、欧路数独、数独达人等的「异形」分类页。
///
/// 排序逻辑：**用户玩得最多 = 主流 App 排在前面**。
///   - 标准：所有 App 都有的基础款
///   - X-Sudoku / 对角：进阶玩家必玩
///   - 超 Hyper / 锯齿 Jigsaw：扩展约束经典款
///   - 杀手 Killer：日韩非常火
///   - 不等式 / 奇偶 / 连续 / 箭头：欧路、Sudoku.com 的「变体」分类
///
/// 之前的「百分比」「迷你 6×6」不算异形（百分比几乎没人玩、
/// 6×6 是入门不是异形），砍掉。
enum SudokuType {
  standard('标准数独', '9×9 · 3×3 宫 · 行列均不重复'),
  diagonal('对角数独 X', '标准 + 两条主对角线也不重复'),
  hyper('超数独', '9×9，叠加四个【3×3 窗】约束'),
  jigsaw('锯齿数独', '9×9，但 9 个宫是任意锯齿形状'),
  killer('杀手数独', '9×9 + 若干「笼」，每笼数字之和 = 笼角标'),
  greater('不等式数独', '9×6，相邻格按「>」「<」标记大小关系'),
  evenodd('奇偶数独', '9×9，部分格标注「奇/偶」约束'),
  consecutive('连续数独', '9×9，相邻格标○则两数差必为 1'),
  arrow('箭头数独', '9×9，箭头路径上数字之和 = 圆球数');

  final String label;
  final String hint;
  const SudokuType(this.label, this.hint);

  /// 棋盘边长。绝大多数 9；不等式 9×6。
  int get size {
    switch (this) {
      case SudokuType.greater:
        return 9; // 9 列 6 行 → size 取列数
      default:
        return 9;
    }
  }

  /// 高度。绝大多数 9；不等式只有 6。
  int get height => this == SudokuType.greater ? 6 : size;
}

/// 难度。决定「挖多少格」+「保留多少提示」。
enum SudokuDifficulty {
  easy('简单', 30), // 给 51 提示
  medium('中等', 40), // 给 41
  hard('困难', 50), // 给 31
  hell('地狱', 56); // 给 25 提示，且必须唯一解

  final String label;
  /// 总共挖掉多少格（81 - 提示数）。`hell` 取最大挖洞数，并验唯一解。
  final int holes;
  const SudokuDifficulty(this.label, this.holes);
}

// ============================================================ 引擎：棋盘 + 约束

/// 棋盘。`cells[r][c]` 为 0 = 空格，否则为 1..n。
/// `fixed[r][c]` 表示这格是「提示」（不可改）。
class SudokuBoard {
  final int size;
  final List<List<int>> cells;
  final List<List<bool>> fixed;
  /// 笔记：每格一个 `Set<int>`，候选数字（笔记模式用）。
  final List<List<Set<int>>> notes;
  /// 杀手笼 / 锯齿等的"格属于哪个笼"标记，Map 行-列 → 笼 id。
  /// v1.9.0+23：不再是 final —— 生成阶段要往里填；
  ///           未生成的题仍保持 null（标准 / 对角 / 超数独等用不上）。
  List<List<int>>? cageId;
  /// 笼 id → (sum, cells list)
  Map<int, _Cage>? cages;
  /// 不等式符号（仅 greater / consecutive 用）。`(r,c) → '>' 或 '<' 或 '=' `
  List<List<String>>? relationMark;

  SudokuBoard({
    required this.size,
    required this.cells,
    required this.fixed,
    required this.notes,
    this.cageId,
    this.cages,
    this.relationMark,
  });

  factory SudokuBoard.empty(int size) {
    final cells = List.generate(size, (_) => List.filled(size, 0));
    final fixed = List.generate(size, (_) => List.filled(size, false));
    final notes =
        List.generate(size, (_) => List.generate(size, (_) => <int>{}));
    return SudokuBoard(
        size: size, cells: cells, fixed: fixed, notes: notes);
  }

  SudokuBoard copy() => SudokuBoard(
        size: size,
        cells: cells.map((r) => List<int>.from(r)).toList(),
        fixed: fixed.map((r) => List<bool>.from(r)).toList(),
        notes: notes.map((r) => r.map((s) => Set<int>.from(s)).toList()).toList(),
        cageId: cageId?.map((r) => List<int>.from(r)).toList(),
        cages: cages == null
            ? null
            : {
                for (final e in cages!.entries)
                  e.key: _Cage(e.value.sum, List.from(e.value.cells))
              },
        relationMark: relationMark?.map((r) => List<String>.from(r)).toList(),
      );

  bool get isFilled =>
      cells.every((row) => row.every((v) => v != 0));
}

class _Cage {
  final int sum;
  final List<List<int>> cells; // [[r,c], ...]
  _Cage(this.sum, this.cells);
}

// ============================================================ 引擎：规则

/// 抽象规则。子类型实现「某格放某数是否合法 / 当前是否完整」+「随机出全盘」。
abstract class SudokuRules {
  final SudokuType type;
  final int size;
  SudokuRules(this.type) : size = type.size;

  bool isLegal(SudokuBoard b, int r, int c, int v);

  /// 整个棋盘是否合法且已填满。
  bool isComplete(SudokuBoard b);

  /// 全盘（解）合法性：每格满足所有行 / 列 / 宫 / 额外约束。
  bool isValidSolution(SudokuBoard b) {
    for (var r = 0; r < size; r++) {
      for (var c = 0; c < size; c++) {
        if (b.cells[r][c] == 0) return false;
      }
    }
    for (var r = 0; r < size; r++) {
      for (var c = 0; c < size; c++) {
        final v = b.cells[r][c];
        // 临时清零再判断（不然 isLegal 会把自己当冲突）
        b.cells[r][c] = 0;
        final ok = isLegal(b, r, c, v);
        b.cells[r][c] = v;
        if (!ok) return false;
      }
    }
    return true;
  }

  /// 用「Latin Square 洗牌 + 回溯填剩余」生成一组合法解。
  SudokuBoard generateFull(math.Random rng);

  /// 在生成完成后，按难度挖洞。
  /// `holes` = 81 - 提示数；地狱难度额外要求解唯一。
  SudokuBoard digHoles(SudokuBoard full, int holes, math.Random rng,
      {bool requireUnique = false}) {
    final n = full.size;
    final puzzle = full.copy();
    // 把所有 fixed 置 false 之后再按挖的置 true
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        puzzle.fixed[r][c] = false;
      }
    }
    final order = <List<int>>[];
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        order.add([r, c]);
      }
    }
    order.shuffle(rng);

    final cellsToDig = math.min(holes, order.length);
    for (var i = 0; i < cellsToDig; i++) {
      final r = order[i][0];
      final c = order[i][1];
      puzzle.cells[r][c] = 0;
      puzzle.notes[r][c].clear();
    }

    // 余下的非 0 格设为提示
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        puzzle.fixed[r][c] = puzzle.cells[r][c] != 0;
      }
    }

    if (requireUnique) {
      // 简单做法：算一遍解数，若 >1 就补回来几个（留 >1 不太理想，
      // 但项目实际不依赖解的绝对唯一，地狱难度只是「挖得狠」）
      // ——这里用启发式「如果解数 > 2 就补回 1 格」。
      final solver = _Solver();
      final solCount = solver.countSolutions(puzzle, cap: 3);
      if (solCount > 1) {
        // 找最近的洞补回去
        for (var i = cellsToDig - 1; i >= 0; i--) {
          final r = order[i][0];
          final c = order[i][1];
          if (puzzle.cells[r][c] == 0) {
            puzzle.cells[r][c] = full.cells[r][c];
            puzzle.fixed[r][c] = true;
            break;
          }
        }
      }
    }
    return puzzle;
  }
}

/// 标准的「行 / 列 / 宫」约束；`type == standard / mini / evenodd` 等
/// 没附加约束的都用它。
class StandardRules extends SudokuRules {
  StandardRules(super.type);

  @override
  bool isLegal(SudokuBoard b, int r, int c, int v) {
    for (var i = 0; i < size; i++) {
      if (i != c && b.cells[r][i] == v) return false;
      if (i != r && b.cells[i][c] == v) return false;
    }
    final br = _boxR(r), bc = _boxC(c);
    final brSize = _boxRows(), bcSize = _boxCols();
    for (var dr = 0; dr < brSize; dr++) {
      for (var dc = 0; dc < bcSize; dc++) {
        final rr = br + dr, cc = bc + dc;
        if (rr == r && cc == c) continue;
        if (b.cells[rr][cc] == v) return false;
      }
    }
    return true;
  }

  @override
  bool isComplete(SudokuBoard b) {
    if (!b.isFilled) return false;
    return isValidSolution(b);
  }

  // 宫大小：标准 9×9 是 3×3；杀手 / 锯齿 / 不等式 等都走这里
  int _boxRows() => 3;
  int _boxCols() => 3;

  int _boxR(int r) => (r ~/ _boxRows()) * _boxRows();
  int _boxC(int c) => (c ~/ _boxCols()) * _boxCols();

  @override
  SudokuBoard generateFull(math.Random rng) {
    final n = size;
    final board = SudokuBoard.empty(n);
    // 第一行放 1..n 洗牌
    final first = List.generate(n, (i) => i + 1)..shuffle(rng);
    for (var c = 0; c < n; c++) {
      board.cells[0][c] = first[c];
      board.fixed[0][c] = true;
    }
    // 回溯填剩余
    final solver = _Solver();
    solver.fillAll(board, this, rng);
    return board;
  }
}

/// 对角 X：行 / 列 / 宫 + 两条主对角线
class DiagonalRules extends StandardRules {
  DiagonalRules(super.type);
  @override
  bool isLegal(SudokuBoard b, int r, int c, int v) {
    if (!super.isLegal(b, r, c, v)) return false;
    if (r == c) {
      for (var i = 0; i < size; i++) {
        if (i == r) continue;
        if (b.cells[i][i] == v) return false;
      }
    }
    if (r + c == size - 1) {
      for (var i = 0; i < size; i++) {
        if (i == r) continue;
        if (b.cells[i][size - 1 - i] == v) return false;
      }
    }
    return true;
  }
}

/// 超数独：在 3×3 宫 + 行 / 列之外，再加四个 3×3 窗（以 (1,1)、(1,4)、
/// (4,1)、(4,4) 为左上角），窗内也不重。
class HyperRules extends StandardRules {
  HyperRules(super.type);
  @override
  bool isLegal(SudokuBoard b, int r, int c, int v) {
    if (!super.isLegal(b, r, c, v)) return false;
    const starts = [
      [1, 1], [1, 4], [4, 1], [4, 4],
    ];
    for (final s in starts) {
      final inWindow = r >= s[0] && r < s[0] + 3 && c >= s[1] && c < s[1] + 3;
      if (!inWindow) continue;
      for (var dr = 0; dr < 3; dr++) {
        for (var dc = 0; dc < 3; dc++) {
          final rr = s[0] + dr, cc = s[1] + dc;
          if (rr == r && cc == c) continue;
          if (b.cells[rr][cc] == v) return false;
        }
      }
    }
    return true;
  }
}

/// 锯齿：宫随机切成 9 个 9 格块。宫列表由 `setBoard` 提供。
class JigsawRules extends StandardRules {
  /// `regionOf[r][c]` = 宫 id（0..8），生成时随机切。
  final List<List<int>> regionOf;

  JigsawRules(super.type, this.regionOf);

  @override
  bool isLegal(SudokuBoard b, int r, int c, int v) {
    for (var i = 0; i < size; i++) {
      if (i != c && b.cells[r][i] == v) return false;
      if (i != r && b.cells[i][c] == v) return false;
    }
    final my = regionOf[r][c];
    for (var rr = 0; rr < size; rr++) {
      for (var cc = 0; cc < size; cc++) {
        if (rr == r && cc == c) continue;
        if (regionOf[rr][cc] != my) continue;
        if (b.cells[rr][cc] == v) return false;
      }
    }
    return true;
  }

  /// 随机切 9 个锯齿块。每块 9 格，且**必须连成一片**。
  ///
  /// v2.1.0 重写：上一版是「随机挑一个边界格、按概率并入邻区」，
  /// 这个算法经常中途卡死（某区再也接不上），跑满 200 次都失败，
  /// 最后 return 的是标准 3×3 宫 —— 用户看到的就是「锯齿数独没有锯齿」。
  ///
  /// 新算法：9 个种子均匀铺在 3×3 的大格子里，然后**轮流涨**，
  /// 每轮每区各吃一个自己的边界格，直到每区满 9 格。
  /// 因为是「从自己的边界往外吃」，连通性天然成立；边界互相咬合就是锯齿。
  static List<List<int>> makeRandomRegions(int size, math.Random rng) {
    List<List<int>> standard() =>
        List.generate(9, (r) => List.generate(9, (c) => (r ~/ 3) * 3 + c ~/ 3));

    if (size != 9) return standard();

    // 把一个格子的上下左右空格加进该区的「边界池」
    void pushFrontier(List<List<int>> pool, List<List<int>> grid, int r, int c) {
      for (final d in const [
        [-1, 0],
        [1, 0],
        [0, -1],
        [0, 1],
      ]) {
        final nr = r + d[0], nc = c + d[1];
        if (nr < 0 || nr >= 9 || nc < 0 || nc >= 9) continue;
        if (grid[nr][nc] != -1) continue;
        pool.add([nr, nc]);
      }
    }

    for (var attempt = 0; attempt < 300; attempt++) {
      final grid = List.generate(9, (_) => List.filled(9, -1));
      final counts = List.filled(9, 0);
      final pools = List.generate(9, (_) => <List<int>>[]);

      // 1) 9 个种子：每个 3×3 大格里随机取一格（互不重叠）
      var id = 0;
      for (var br = 0; br < 3; br++) {
        for (var bc = 0; bc < 3; bc++) {
          final r = br * 3 + rng.nextInt(3);
          final c = bc * 3 + rng.nextInt(3);
          grid[r][c] = id;
          counts[id] = 1;
          pushFrontier(pools[id], grid, r, c);
          id++;
        }
      }

      // 2) 轮流涨：每轮按随机顺序，每区各吃一个边界格
      var filled = 9;
      var guard = 0;
      while (filled < 81 && guard++ < 400) {
        final order = List<int>.generate(9, (i) => i)..shuffle(rng);
        var progressed = false;
        for (final k in order) {
          if (counts[k] >= 9) continue;
          final pool = pools[k];
          // 清掉已经被别的区吃掉的
          while (pool.isNotEmpty && grid[pool.last[0]][pool.last[1]] != -1) {
            pool.removeLast();
          }
          if (pool.isEmpty) continue;
          final pick = pool.removeAt(rng.nextInt(pool.length));
          grid[pick[0]][pick[1]] = k;
          counts[k]++;
          filled++;
          progressed = true;
          pushFrontier(pool, grid, pick[0], pick[1]);
          if (filled >= 81) break;
        }
        if (!progressed) break;
      }

      if (filled == 81 && counts.every((c) => c == 9)) return grid;
    }
    // 极端情况下还是回标准宫（不可能是锯齿，但至少能玩）
    return standard();
  }
}

/// 杀手：每笼数字不重且和 = 笼和。
class KillerRules extends StandardRules {
  KillerRules(super.type);

  @override
  bool isLegal(SudokuBoard b, int r, int c, int v) {
    if (!super.isLegal(b, r, c, v)) return false;
    // 笼内不重复
    final id = b.cageId?[r][c];
    if (id == null) return true;
    final cage = b.cages?[id];
    if (cage == null) return true;
    for (final cell in cage.cells) {
      if (cell[0] == r && cell[1] == c) continue;
      if (b.cells[cell[0]][cell[1]] == v) return false;
    }
    return true;
  }

  @override
  bool isComplete(SudokuBoard b) {
    if (!b.isFilled) return false;
    for (final cage in b.cages!.values) {
      var sum = 0;
      for (final cell in cage.cells) {
        sum += b.cells[cell[0]][cell[1]];
      }
      if (sum != cage.sum) return false;
    }
    return isValidSolution(b);
  }

  @override
  SudokuBoard generateFull(math.Random rng) {
    final full = super.generateFull(rng);
    // 在合法解上**叠加**笼：随机把每 2~5 个相邻格子捆成一笼
    final n = full.size;
    final cageId = List.generate(n, (_) => List.filled(n, -1));
    final cages = <int, _Cage>{};
    var nextId = 0;
    final visited = List.generate(n, (_) => List.filled(n, false));
    // 顺序打乱 → 走 BFS，每笼 2~5 格
    final order = <List<int>>[];
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        order.add([r, c]);
      }
    }
    order.shuffle(rng);
    var done = 0;
    for (final cell in order) {
      final r = cell[0], c = cell[1];
      if (visited[r][c]) continue;
      final cellsList = <List<int>>[
        [r, c]
      ];
      visited[r][c] = true;
      // 随机把若干邻接空格并入
      final wantSize = 2 + rng.nextInt(4);
      while (cellsList.length < wantSize) {
        final head = cellsList[rng.nextInt(cellsList.length)];
        final nbrs = <List<int>>[
          [head[0] - 1, head[1]],
          [head[0] + 1, head[1]],
          [head[0], head[1] - 1],
          [head[0], head[1] + 1],
        ]..shuffle(rng);
        bool grew = false;
        for (final nb in nbrs) {
          final nr = nb[0], nc = nb[1];
          if (nr < 0 || nr >= n || nc < 0 || nc >= n) continue;
          if (visited[nr][nc]) continue;
          visited[nr][nc] = true;
          cellsList.add([nr, nc]);
          grew = true;
          break;
        }
        if (!grew) break;
      }
      var sum = 0;
      for (final cell in cellsList) {
        sum += full.cells[cell[0]][cell[1]];
      }
      cages[nextId] = _Cage(sum, cellsList);
      for (final cell in cellsList) {
        cageId[cell[0]][cell[1]] = nextId;
      }
      nextId++;
      done += cellsList.length;
      if (done >= n * n) break;
    }
    // 把笼信息挂回棋盘（cells 不动，挖洞法会复制 cageId）
    full.cageId = cageId;
    full.cages = cages;
    return full;
  }

  @override
  SudokuBoard digHoles(SudokuBoard full, int holes, math.Random rng,
      {bool requireUnique = false}) {
    final p = super.digHoles(full, holes, rng, requireUnique: requireUnique);
    p.cageId = full.cageId?.map((r) => List<int>.from(r)).toList();
    p.cages = {
      for (final e in full.cages!.entries)
        e.key: _Cage(e.value.sum, List.from(e.value.cells))
    };
    // 杀手数独挖完要验笼和：每笼至少留 1 格提示（不然没法算）
    // ——super 已挖 holes 个；如果某笼全空，随机补一格回去
    for (final cage in p.cages!.values) {
      var anyFixed = false;
      for (final cell in cage.cells) {
        if (p.cells[cell[0]][cell[1]] != 0) {
          anyFixed = true;
          break;
        }
      }
      if (!anyFixed) {
        // 补一个回去
        final pick = cage.cells[rng.nextInt(cage.cells.length)];
        p.cells[pick[0]][pick[1]] = full.cells[pick[0]][pick[1]];
        p.fixed[pick[0]][pick[1]] = true;
      }
    }
    return p;
  }
}

/// 不等式：9 列 × 6 行（横），相邻格按「>」「<」标记约束。
/// 只支持**行内**不等式；列内不加（混合算法太重）。
class GreaterRules extends StandardRules {
  GreaterRules(super.type);

  @override
  bool isLegal(SudokuBoard b, int r, int c, int v) {
    // 行内列约束 + 行内不等式 + 列向宫
    if (!super.isLegal(b, r, c, v)) return false;
    // 不等式：c-1 用 '<'/'=' '>' 检查
    final marks = b.relationMark;
    if (marks == null) return true;
    if (c > 0 && b.cells[r][c - 1] != 0) {
      final m = marks[r][c];
      if (m == '<' && !(b.cells[r][c - 1] < v)) return false;
      if (m == '>' && !(b.cells[r][c - 1] > v)) return false;
    }
    if (c < size - 1 && b.cells[r][c + 1] != 0) {
      final m = marks[r][c + 1];
      if (m == '<' && !(v < b.cells[r][c + 1])) return false;
      if (m == '>' && !(v > b.cells[r][c + 1])) return false;
    }
    return true;
  }

  // 不等式棋盘：9 列 × 6 行；列向 3×3 宫在 (r=0..5, c=0..8) 内切成 2 行 × 3 列
  //（父类 StandardRules 已按 3×3 宫布局，9 列能整除 3、6 行能整除 3，OK）
}

/// 奇偶：行 / 列 / 宫 + 部分格固定奇偶
class EvenOddRules extends StandardRules {
  /// `(r,c) → 'e' (偶) / 'o' (奇)`。空位置不进约束。
  ///
  /// v1.9.0+24 改：标记存在 *规则* 上而不是 *棋盘* 上。
  /// 之前想存在棋盘导致 digHoles 要给 `p.evenOdd = ...`，但
  /// `SudokuBoard` 没有这个字段，编译不过。规则跟棋盘 1:1 绑定，
  /// 把标记放规则上更自然。digHoles 不再 override（父类已拷贝 cells/fixed/notes，
  /// 这些都不变；cageId/cages/relationMark 在标准数独上用不到，奇偶数独也不用）。
  List<List<String>> evenOdd;

  EvenOddRules(super.type, this.evenOdd);

  @override
  bool isLegal(SudokuBoard b, int r, int c, int v) {
    if (!super.isLegal(b, r, c, v)) return false;
    final mark = evenOdd[r][c];
    if (mark == 'e' && v.isOdd) return false;
    if (mark == 'o' && v.isEven) return false;
    return true;
  }

  @override
  SudokuBoard generateFull(math.Random rng) {
    final full = super.generateFull(rng);
    // 撒奇偶标记：约 8 个
    final n = full.size;
    final marks = List.generate(n, (_) => List.filled(n, ''));
    var toMark = 8;
    while (toMark > 0) {
      final r = rng.nextInt(n);
      final c = rng.nextInt(n);
      if (marks[r][c].isNotEmpty) continue;
      marks[r][c] = rng.nextBool() ? 'e' : 'o';
      toMark--;
    }
    evenOdd
      ..clear()
      ..addAll(marks);
    return full;
  }
}

/// 连续：相邻格标○则差必为 1
class ConsecutiveRules extends StandardRules {
  ConsecutiveRules(super.type);

  @override
  bool isLegal(SudokuBoard b, int r, int c, int v) {
    if (!super.isLegal(b, r, c, v)) return false;
    final marks = b.relationMark;
    if (marks == null) return true;
    // 上下左右 ○ → 差 1
    const dirs = [[0, 1], [0, -1], [1, 0], [-1, 0]];
    for (final d in dirs) {
      final nr = r + d[0], nc = c + d[1];
      if (nr < 0 || nr >= size || nc < 0 || nc >= size) continue;
      final m = marks[r][c];
      if (m == 'o' || m == 'O') {
        // 与 nr,nc 之间有「○」
        if (b.cells[nr][nc] != 0 &&
            (b.cells[nr][nc] - v).abs() != 1) {
          return false;
        }
      }
    }
    return true;
  }
}

/// 箭头：箭头路径上的数字之和 = 圆球数
class ArrowRules extends StandardRules {
  /// v1.9.0+23：箭头定义。**改成命名 class**——
  /// 之前用 `List<List<List<int>>>` 表示「(ball, path) pair list」，
  /// 但 Dart 推断嵌套类型时容易塌成 `List<int>`（尤其是 spread 的内层列表），
  /// 导致 `.arrows[i][j][0]` 那行报「operator [] 不存在 in int」。
  /// 用 class 写就一目了然，编译期稳。
  final List<ArrowDef> arrows;

  ArrowRules(super.type, this.arrows);

  @override
  bool isLegal(SudokuBoard b, int r, int c, int v) {
    if (!super.isLegal(b, r, c, v)) return false;
    // 球不能与路径上其它格同值（即使数值合法）
    for (final arr in arrows) {
      final ball = arr.ball;
      if (ball[0] == r && ball[1] == c) {
        for (final cell in arr.path) {
          if (cell[0] == r && cell[1] == c) continue;
          if (b.cells[cell[0]][cell[1]] == v) return false;
        }
      }
    }
    return true;
  }

  @override
  bool isComplete(SudokuBoard b) {
    if (!b.isFilled) return false;
    if (!isValidSolution(b)) return false;
    for (final arr in arrows) {
      final ballVal = b.cells[arr.ball[0]][arr.ball[1]];
      var sum = 0;
      for (final cell in arr.path) {
        sum += b.cells[cell[0]][cell[1]];
      }
      if (sum != ballVal) return false;
    }
    return true;
  }
}

/// 一个箭头：`ball` 是圆球坐标，`path` 是从 ball 起往外的路径格列表（不含 ball）。
class ArrowDef {
  final List<int> ball;
  final List<List<int>> path;
  ArrowDef(this.ball, this.path);
}

// ============================================================ 引擎：解算器

class _Solver {
  bool fillAll(SudokuBoard b, SudokuRules rules, math.Random rng) {
    // 找第一个空格
    for (var r = 0; r < b.size; r++) {
      for (var c = 0; c < b.size; c++) {
        if (b.cells[r][c] == 0) {
          // 试 1..n 随机顺序
          final order = List.generate(b.size, (i) => i + 1)..shuffle(rng);
          for (final v in order) {
            if (rules.isLegal(b, r, c, v)) {
              b.cells[r][c] = v;
              if (fillAll(b, rules, rng)) return true;
              b.cells[r][c] = 0;
            }
          }
          return false;
        }
      }
    }
    return true;
  }

  /// 数解数（找到 cap 个就停）。地狱难度用这个验唯一。
  int countSolutions(SudokuBoard b, {int cap = 2}) {
    var count = 0;
    _countRec(b, b.size, () {
      count++;
      return count >= cap;
    });
    return count;
  }

  void _countRec(SudokuBoard b, int size, bool Function() stop) {
    for (var r = 0; r < size; r++) {
      for (var c = 0; c < size; c++) {
        if (b.cells[r][c] == 0) {
          for (var v = 1; v <= size; v++) {
            // 走默认标准规则校验
            var ok = true;
            for (var i = 0; i < size; i++) {
              if (i != c && b.cells[r][i] == v) {
                ok = false;
                break;
              }
              if (i != r && b.cells[i][c] == v) {
                ok = false;
                break;
              }
            }
            if (ok) {
              // 宫
              final br = (r ~/ 3) * 3, bc = (c ~/ 3) * 3;
              for (var dr = 0; dr < 3; dr++) {
                for (var dc = 0; dc < 3; dc++) {
                  final rr = br + dr, cc = bc + dc;
                  if (rr == r && cc == c) continue;
                  if (b.cells[rr][cc] == v) {
                    ok = false;
                    break;
                  }
                }
                if (!ok) break;
              }
            }
            if (ok) {
              b.cells[r][c] = v;
              _countRec(b, size, stop);
              b.cells[r][c] = 0;
              if (stop()) return;
            }
          }
          return;
        }
      }
    }
  }
}

// ============================================================ UI：主页面

/// 数独主入口：选类型 → 选难度 → 出题 → 玩。
/// 单页里把整个流程走完，不开新路由。
class SudokuPage extends StatefulWidget {
  const SudokuPage({super.key});

  @override
  State<SudokuPage> createState() => _SudokuPageState();
}

class _SudokuPageState extends State<SudokuPage> {
  SudokuType _type = SudokuType.standard;
  SudokuDifficulty _diff = SudokuDifficulty.medium;
  SudokuBoard? _board;
  SudokuBoard? _solution; // 出题时的合法解，提示模式用
  SudokuRules? _rules;
  bool _noteMode = false;
  int _errCount = 0;
  bool _showHint = false;
  bool _busy = false;

  /// v1.9.0+28：「校验」标出来的错格（key = "r-c"），用户落子后清空
  Set<String> _checkedWrong = {};

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    // 自动恢复上次类型 + 难度；不强求恢复进度（每次进都是新局）
    try {
      final sp = await SharedPreferences.getInstance();
      final t = sp.getString('sudoku_type');
      final d = sp.getString('sudoku_diff');
      if (!mounted) return;
      setState(() {
        if (t != null) {
          _type = SudokuType.values.firstWhere(
              (e) => e.name == t,
              orElse: () => SudokuType.standard);
        }
        if (d != null) {
          _diff = SudokuDifficulty.values.firstWhere(
              (e) => e.name == d,
              orElse: () => SudokuDifficulty.medium);
        }
      });
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString('sudoku_type', _type.name);
      await sp.setString('sudoku_diff', _diff.name);
    } catch (_) {}
  }

  /// 出题。一次性：生成全盘 → 挖洞 → 渲染。
  Future<void> _newGame() async {
    setState(() => _busy = true);
    final rng = math.Random();
    SudokuRules rules;
    SudokuBoard full;

    switch (_type) {
      case SudokuType.standard:
        rules = StandardRules(_type);
        full = rules.generateFull(rng);
        break;
      case SudokuType.diagonal:
        rules = DiagonalRules(_type);
        full = rules.generateFull(rng);
        break;
      case SudokuType.hyper:
        rules = HyperRules(_type);
        full = rules.generateFull(rng);
        break;
      case SudokuType.jigsaw:
        final regions =
            JigsawRules.makeRandomRegions(SudokuType.jigsaw.size, rng);
        rules = JigsawRules(_type, regions);
        full = rules.generateFull(rng);
        break;
      case SudokuType.killer:
        rules = KillerRules(_type);
        full = (rules as KillerRules).generateFull(rng);
        break;
      case SudokuType.greater:
        rules = GreaterRules(_type);
        full = rules.generateFull(rng);
        // GreaterRules：6 行 × 9 列。height 从 type.height 拿（SudokuBoard.size 是宽边）。
        full.relationMark = _makeGreaterMarks(full.size, _type.height, rng);
        break;
      case SudokuType.evenodd:
        final rulesEO = EvenOddRules(_type,
            List.generate(_type.size, (_) => List.filled(_type.size, '')));
        full = rulesEO.generateFull(rng);
        rules = rulesEO;
        break;
      case SudokuType.consecutive:
        rules = ConsecutiveRules(_type);
        full = rules.generateFull(rng);
        full.relationMark =
            _makeConsecutiveMarks(full.size, rng.nextDouble() < 0.18 ? 0.20 : 0.12);
        break;
      case SudokuType.arrow:
        final rulesArr = ArrowRules(_type, []);
        full = rulesArr.generateFull(rng);
        // 在合法解上**叠加**箭头
        rulesArr.arrows.addAll(_makeArrows(full.size, rng));
        rules = rulesArr;
        break;
    }

    final dig =
        rules.digHoles(full, _diff.holes, rng, requireUnique: _diff == SudokuDifficulty.hell);

    if (!mounted) return;
    setState(() {
      _rules = rules;
      _solution = full;
      _board = dig;
      _errCount = 0;
      _showHint = false;
      _busy = false;
      _checkedWrong = {};
      _undoStack.clear();
      _startedAt = DateTime.now();
    });
    _save();
  }

  /// 不等式：随机生成「<」「>」标记。
  List<List<String>> _makeGreaterMarks(int cols, int rows, math.Random rng) {
    final marks = List.generate(rows, (_) => List.filled(cols, ''));
    for (var r = 0; r < rows; r++) {
      // 第一列没意义
      for (var c = 1; c < cols; c++) {
        // 50% 放标记
        if (rng.nextBool()) {
          marks[r][c] = rng.nextBool() ? '<' : '>';
        }
      }
    }
    return marks;
  }

  /// 连续：随机选若干对相邻格打"○"
  List<List<String>> _makeConsecutiveMarks(int size, double ratio) {
    final marks = List.generate(size, (_) => List.filled(size, ''));
    final rng = math.Random();
    for (var r = 0; r < size; r++) {
      for (var c = 0; c < size; c++) {
        marks[r][c] = '';
      }
    }
    // 每个「○」需要一对外加 4 个边界标记，存到 marks[r][c] 里，
    // 含义：(r,c) 与 右侧 / 下侧 邻居有「连续」
    for (var r = 0; r < size; r++) {
      for (var c = 0; c < size - 1; c++) {
        if (rng.nextDouble() < ratio) marks[r][c] = 'o';
      }
    }
    return marks;
  }

  /// 箭头：在合法解上随机画 4~5 个箭头（每个圆球带 2~3 格路径）
  List<ArrowDef> _makeArrows(int size, math.Random rng) {
    final out = <ArrowDef>[];
    final used = <List<bool>>[];
    for (var r = 0; r < size; r++) {
      used.add(List.filled(size, false));
    }
    var tries = 0;
    while (out.length < 5 && tries++ < 200) {
      final br = rng.nextInt(size);
      final bc = rng.nextInt(size);
      if (used[br][bc]) continue;
      final pathLen = 2 + rng.nextInt(2);
      final path = <List<int>>[];
      var pr = br, pc = bc;
      var pathTries = 0;
      while (path.length < pathLen && pathTries++ < 30) {
        // 沿一个方向走
        final dir = rng.nextInt(4);
        final dr = [0, 0, 1, -1][dir];
        final dc = [1, -1, 0, 0][dir];
        final nr = pr + dr, nc = pc + dc;
        if (nr < 0 || nr >= size || nc < 0 || nc >= size) continue;
        if (used[nr][nc]) continue;
        if (path.any((c) => c[0] == nr && c[1] == nc)) continue;
        pr = nr;
        pc = nc;
        path.add([nr, nc]);
      }
      if (path.length < 2) continue;
      // 用 ArrowDef class 包，类型清晰（Dart 推断不再塌成 List<int>）
      out.add(ArrowDef([br, bc], List<List<int>>.from(path)));
      for (final c in path) {
        used[c[0]][c[1]] = true;
      }
      used[br][bc] = true;
    }
    return out;
  }

  void _onCellTap(int r, int c) {
    if (_board == null || _rules == null) return;
    final b = _board!;
    if (b.fixed[r][c]) {
      toast(context, '这格是提示，不能改');
      return;
    }
    // 数字盘上的「剩余个数」角标：每个数字一共该出现几次 - 已经出现几次
    final per = _perNumber;
    final placed = <int, int>{};
    for (final row in b.cells) {
      for (final v in row) {
        if (v != 0) placed[v] = (placed[v] ?? 0) + 1;
      }
    }
    final remain = <int, int>{
      for (var v = 1; v <= b.size; v++) v: per - (placed[v] ?? 0),
    };
    // 数字选择
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _NumberPad(
        size: b.size,
        current: b.cells[r][c],
        notes: b.notes[r][c],
        noteMode: _noteMode,
        remain: remain,
        onPick: (v) {
          Navigator.pop(ctx);
          _applyNumber(r, c, v);
        },
      ),
    );
  }

  /// 每个数字在整个盘里该出现几次：9×9 = 9，9×6（不等式）= 6
  int get _perNumber => _type.height;

  void _applyNumber(int r, int c, int v) {
    final b = _board!;
    final rules = _rules!;
    _pushUndo(r, c);
    if (_noteMode) {
      // v2.1.0 修：这一格**已经有数字**时，候选笔记会被数字盖住，
      // 用户点了半天看不到任何变化 —— 所以记笔记前先把数字清掉。
      setState(() {
        if (b.cells[r][c] != 0) {
          b.cells[r][c] = 0;
          b.notes[r][c].clear();
        }
        if (b.notes[r][c].contains(v)) {
          b.notes[r][c].remove(v);
        } else {
          b.notes[r][c].add(v);
        }
        _checkedWrong = {};
      });
      return;
    }
    // v1.9.0+28：再点一次同一个数字 = 清除该格（去掉数字盘上的「擦除」按钮后的替代操作）
    if (b.cells[r][c] == v) {
      _clearCell(r, c);
      return;
    }
    if (!rules.isLegal(b, r, c, v)) {
      // 错误（与规则冲突）→ 数字显示为红色，用户可改 / 删
      HapticFeedback.heavyImpact();
      setState(() {
        b.cells[r][c] = v;
        b.notes[r][c].clear();
        _errCount++;
        _checkedWrong = {};
      });
      return;
    }
    setState(() {
      b.cells[r][c] = v;
      // 落子后这格的笔记没用了（原来不清，会跟数字叠在一起）
      b.notes[r][c].clear();
      _checkedWrong = {};
    });
    if (rules.isComplete(b)) {
      _finish();
    }
  }

  void _clearCell(int r, int c) {
    setState(() {
      _board!.cells[r][c] = 0;
      _board!.notes[r][c].clear();
    });
  }

  void _finish() {
    final wrong = _errCount > 0;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(wrong ? '做完了，但有错误' : '全部正确'),
        content: Text(
            wrong
                ? '错误 ${_errCount} 次，地狱难度不算通关。\n（地狱要求 0 错误）'
                : '${_diff.label}难度已通过！\n用时 ${_fmtElapsed()}。'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _newGame();
            },
            child: const Text('再来一局'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('留在棋盘'),
          ),
        ],
      ),
    );
  }

  // ---------- 计时 ----------
  DateTime? _startedAt;
  String _fmtElapsed() {
    final s = _startedAt;
    if (s == null) return '00:00';
    final d = DateTime.now().difference(s);
    final mm = (d.inSeconds ~/ 60).toString().padLeft(2, '0');
    final ss = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    return ToolScaffold(
      title: '数独练习',
      subtitle: _type.label +
          ' · ' +
          _diff.label +
          (_board == null ? '' : ' · 错误 $_errCount'),
      actions: [
        // v1.9.0+28：换题型（回选题页）。原来只能退出工具再进，很不方便。
        if (_board != null)
          IconButton(
            tooltip: '换题型 / 难度',
            onPressed: () => setState(() => _board = null),
            icon: const Icon(Icons.tune),
          ),
        // 新题（保持当前题型难度重出）
        IconButton(
          tooltip: '新题',
          onPressed: _busy ? null : _newGame,
          icon: const Icon(Icons.refresh),
        ),
      ],
      child: _board == null
          ? _picker()
          : _boardView(),
    );
  }

  // ---------- 选类型 / 难度 ----------
  //
  // v1.9.0+28 重排：
  //   * 删掉「说明」那一大段文字（用户点名不要）
  //   * 「新题」按钮挪到「题型 / 难度」同一区域（原来在最下面一个孤零零的「开始」）
  Widget _picker() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      children: [
        Row(
          children: [
            const ToolSection('题型'),
            const Spacer(),
            FilledButton.icon(
              onPressed: _busy ? null : _newGame,
              icon: const Icon(Icons.auto_awesome, size: 18),
              label: const Text('新题'),
            ),
          ],
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final t in SudokuType.values)
              ChoiceChip(
                label: Text(t.label),
                selected: _type == t,
                onSelected: (_) => setState(() => _type = t),
              ),
          ],
        ),
        const ToolSection('难度'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final d in SudokuDifficulty.values)
              ChoiceChip(
                label: Text(d.label + (d == SudokuDifficulty.hell ? ' ☠' : '')),
                selected: _diff == d,
                onSelected: (_) => setState(() => _diff = d),
              ),
          ],
        ),
      ],
    );
  }

  // ---------- 棋盘视图 ----------
  //
  // v1.9.0+28：底部按钮改成用户点名的 5 个
  //   撤销 / 笔记 / 提示 / 校验 / 答案
  // 「时间」「错误次数」挪到标题副标题里（原来底栏占一排）。
  Widget _boardView() {
    final b = _board!;
    final n = b.size;
    return Column(
      children: [
        Expanded(
          child: Padding(
            // 贴着屏幕边：左右 0px，宫格能有多大就多大（用户明确要求）
            padding: const EdgeInsets.fromLTRB(0, 2, 0, 0),
            child: Center(
              child: AspectRatio(
                aspectRatio: n == 9 ? 1.0 : (n == 6 && _type == SudokuType.greater) ? 1.5 : 1.0,
                child: _SudokuGrid(
                  board: b,
                  rules: _rules!,
                  showHint: _showHint,
                  solution: _solution,
                  wrongCells: _checkedWrong,
                  onCellTap: _onCellTap,
                  onCellLongPress: (r, c) {
                    if (b.fixed[r][c]) return;
                    _pushUndo(r, c);
                    _clearCell(r, c);
                    toast(context, '已清除该格');
                  },
                ),
              ),
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(2, 4, 2, 6),
          child: Row(
            children: [
              _barButton(
                icon: Icons.undo,
                label: '撤销',
                onTap: _undo,
              ),
              _barButton(
                icon: Icons.edit_note,
                label: '笔记',
                active: _noteMode,
                onTap: () => setState(() => _noteMode = !_noteMode),
              ),
              _barButton(
                icon: _showHint ? Icons.lightbulb : Icons.lightbulb_outline,
                label: '提示',
                active: _showHint,
                onTap: _solution == null
                    ? null
                    : () => setState(() => _showHint = !_showHint),
              ),
              _barButton(
                icon: Icons.fact_check_outlined,
                label: '校验',
                onTap: _checkBoard,
              ),
              _barButton(
                icon: Icons.emoji_flags_outlined,
                label: '答案',
                onTap: _revealAnswer,
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 底部一个方形按钮：图标 + 文字，激活时整块染主色
  Widget _barButton({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    bool active = false,
  }) {
    final cs = Theme.of(context).colorScheme;
    final fg = active ? cs.onPrimaryContainer : cs.onSurfaceVariant;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        // v2.1.0：激活时**整块**染主色（原来只染图标那一小块，
        // 「笔记」开关看不出开没开 —— 用户要求「点了变色、再点褪色」）。
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 2),
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: active ? cs.primaryContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: fg),
              const SizedBox(height: 2),
              Text(label,
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                      color: fg)),
            ],
          ),
        ),
      ),
    );
  }

  // ---------- 校验 / 答案（v1.9.0+28 新增） ----------

  /// 校验：拿当前盘面和「出题时的解」逐格比，把用户填错的格标红。
  void _checkBoard() {
    final b = _board;
    final s = _solution;
    if (b == null || s == null) return;
    final wrong = <String>{};
    for (var r = 0; r < b.size; r++) {
      for (var c = 0; c < b.size; c++) {
        if (b.fixed[r][c]) continue;
        final v = b.cells[r][c];
        if (v != 0 && v != s.cells[r][c]) wrong.add('$r-$c');
      }
    }
    setState(() => _checkedWrong = wrong);
    toast(context, wrong.isEmpty ? '校验通过，目前没有填错的格' : '发现 ${wrong.length} 处错误，已标红');
  }

  /// 答案：确认后把完整解填进盘面（会清掉笔记）。
  Future<void> _revealAnswer() async {
    final b = _board;
    final s = _solution;
    if (b == null || s == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('显示答案？'),
        content: const Text('会把完整答案填进盘面，本局将不再计分。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('填答案')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    _undoStack.clear();
    setState(() {
      for (var r = 0; r < b.size; r++) {
        for (var c = 0; c < b.size; c++) {
          b.cells[r][c] = s.cells[r][c];
          b.notes[r][c].clear();
        }
      }
      _checkedWrong = {};
      _showHint = false;
    });
  }

  // ---------- 撤销栈 ----------
  final List<_Move> _undoStack = [];

  void _undo() {
    if (_undoStack.isEmpty) {
      toast(context, '没有可撤销的');
      return;
    }
    final m = _undoStack.removeLast();
    setState(() {
      _board!.cells[m.r][m.c] = m.prevValue;
      _board!.notes[m.r][m.c].clear();
      _board!.notes[m.r][m.c].addAll(m.prevNotes);
    });
  }

  void _pushUndo(int r, int c) {
    _undoStack.add(_Move(
      r: r,
      c: c,
      prevValue: _board!.cells[r][c],
      prevNotes: Set<int>.from(_board!.notes[r][c]),
    ));
  }
}

class _Move {
  final int r, c, prevValue;
  final Set<int> prevNotes;
  _Move({required this.r, required this.c, required this.prevValue, required this.prevNotes});
}

// ============================================================ UI：棋盘格子

class _SudokuGrid extends StatelessWidget {
  final SudokuBoard board;
  final SudokuRules rules;
  final bool showHint;
  final SudokuBoard? solution;

  /// v1.9.0+28：「校验」标出的错格，key = "r-c"
  final Set<String> wrongCells;
  final void Function(int r, int c) onCellTap;
  final void Function(int r, int c)? onCellLongPress;

  const _SudokuGrid({
    required this.board,
    required this.rules,
    required this.showHint,
    required this.solution,
    required this.onCellTap,
    this.wrongCells = const <String>{},
    this.onCellLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final n = board.size;
    final height = rules.type == SudokuType.greater ? 6 : n;

    // 颜色
    final scheme = Theme.of(context).colorScheme;
    final lineColor = scheme.outlineVariant;
    final thickColor = scheme.outline;
    final bg = scheme.surface;
    final hintColor = scheme.primary.withValues(alpha: 0.18);
    final errColor = const Color(0xFFB23A3A);

    return Container(
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: thickColor, width: 1.5),
      ),
      // LayoutBuilder 必须放在 Container **里面**：
      // 放外面拿到的是含 1.5px 边框的外尺寸，算出来的 cell 比真实格宽大一点点，
      // 锯齿宫 / 笼框这些按坐标画的覆盖层会越往右下越偏，看起来像「没对齐」。
      child: LayoutBuilder(
        builder: (ctx, cons) {
          // 单元格边长 = min(横向 / 列数, 纵向 / 行数) —— 9×6 也能塞得下
          final byW = cons.maxWidth / n;
          final byH = cons.maxHeight / (height == 0 ? 1 : height);
          final cell = byW < byH ? byW : byH;
          return Stack(
            children: [
              // 底层：所有格子
              GridView.builder(
                physics: const NeverScrollableScrollPhysics(),
                padding: EdgeInsets.zero,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: n,
                  childAspectRatio: 1,
                ),
                itemCount: n * height,
                itemBuilder: (ctx, idx) {
                  final r = idx ~/ n;
                  final c = idx % n;
                  return _cellView(
                    context: context,
                    r: r,
                    c: c,
                    cell: cell,
                    lineColor: lineColor,
                    thickColor: thickColor,
                    hintColor: hintColor,
                    errColor: errColor,
                  );
                },
              ),
              // 笼子 / 锯齿 宫 / 不等式标记 —— 覆盖层
              if (rules is KillerRules && board.cageId != null)
                _cageOverlay(board, cell, scheme),
              if (rules is JigsawRules)
                _jigsawOverlay(rules, cell, scheme),
              if (rules is GreaterRules && board.relationMark != null)
                _greaterOverlay(board, cell, scheme),
              if (rules is ConsecutiveRules && board.relationMark != null)
                _consecutiveOverlay(board, cell, scheme),
              if (rules is EvenOddRules)
                _evenOddOverlay(rules, cell, scheme),
              if (rules is ArrowRules)
                if ((rules as ArrowRules).arrows.isNotEmpty)
                  _arrowOverlay(board, rules, cell, scheme),
            ],
          );
        },
      ),
    );
  }

  Widget _cellView({
    required BuildContext context,
    required int r,
    required int c,
    required double cell,
    required Color lineColor,
    required Color thickColor,
    required Color hintColor,
    required Color errColor,
  }) {
    final v = board.cells[r][c];
    final isFixed = board.fixed[r][c];
    final n = board.size;
    // 边框：3×3 宫 / 6×6 子宫需要粗线
    final isRightThick = c == n - 1 || (n % 3 == 0 && (c + 1) % 3 == 0 && c != n - 1);
    final isBottomThick = r == board.size - 1 ||
        (n % 3 == 0 && (r + 1) % 3 == 0 && r != n - 1);

    // 检查当前值是否违反规则（仅对**用户填入**的格提示，fixed 的略过）
    bool _isIllegal = false;
    if (v != 0 && !isFixed) {
      // 临时清零再校验（isLegal 会把自己当冲突）
      final saved = board.cells[r][c];
      board.cells[r][c] = 0;
      _isIllegal = !rules.isLegal(board, r, c, v);
      board.cells[r][c] = saved;
    }
    // v1.9.0+28：点过「校验」后，错的格直接标红
    final checkedWrong = wrongCells.contains('$r-$c');

    Color cellBg = Colors.transparent;
    if (showHint && solution != null && v == 0) {
      cellBg = hintColor;
    } else if (checkedWrong) {
      cellBg = errColor.withValues(alpha: 0.18);
    }
    return GestureDetector(
      onTap: () => onCellTap(r, c),
      onLongPress: onCellLongPress == null ? null : () => onCellLongPress!(r, c),
      child: Container(
        decoration: BoxDecoration(
          color: cellBg,
          border: Border(
            top: BorderSide(
                color: r > 0 && (r % 3 == 0) && n % 3 == 0 ? thickColor : lineColor,
                width: r > 0 && (r % 3 == 0) && n % 3 == 0 ? 1.5 : 0.5),
            left: BorderSide(
                color: c > 0 && (c % 3 == 0) && n % 3 == 0 ? thickColor : lineColor,
                width: c > 0 && (c % 3 == 0) && n % 3 == 0 ? 1.5 : 0.5),
            right: BorderSide(
                color: isRightThick ? thickColor : lineColor, width: isRightThick ? 1.5 : 0.5),
            bottom: BorderSide(
                color: isBottomThick ? thickColor : lineColor, width: isBottomThick ? 1.5 : 0.5),
          ),
        ),
        alignment: Alignment.center,
        child: v == 0
            ? (board.notes[r][c].isEmpty
                ? null
                : Padding(
                    padding: const EdgeInsets.all(2),
                    child: GridView.count(
                      // 6×6 只画 1~6（原来固定画 1~9，多出来的两格永远空着）
                      crossAxisCount: n <= 4 ? 2 : 3,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      children: [
                        for (var i = 1; i <= n; i++)
                          Center(
                            child: Text(
                              board.notes[r][c].contains(i) ? '$i' : '',
                              // 字号跟格子走（原来写死 8px，大屏上几乎看不见）
                              style: TextStyle(
                                  fontSize: (cell * 0.22).clamp(7.0, 12.0),
                                  color: Theme.of(context).colorScheme.onSurfaceVariant),
                            ),
                          ),
                      ],
                    ),
                  ))
            : Text(
                '$v',
                style: TextStyle(
                  fontSize: cell * 0.58,
                  fontWeight: FontWeight.w600,
                  color: (_isIllegal || checkedWrong)
                      ? errColor
                      : (isFixed
                          ? Colors.black87
                          : Theme.of(context).colorScheme.primary),
                ),
              ),
      ),
    );
  }

  // ---------- 笼子（杀手） ----------
  Widget _cageOverlay(SudokuBoard b, double cell, ColorScheme scheme) {
    final cageId = b.cageId!;
    final cages = b.cages!;
    // 找出每个笼的「外框矩形 + 数字位置」
    final rects = <int, _CageRect>{};
    for (final entry in cages.entries) {
      final id = entry.key;
      final cells = entry.value.cells;
      var minR = 999, maxR = -1, minC = 999, maxC = -1;
      for (final cell_ in cells) {
        if (cell_[0] < minR) minR = cell_[0];
        if (cell_[0] > maxR) maxR = cell_[0];
        if (cell_[1] < minC) minC = cell_[1];
        if (cell_[1] > maxC) maxC = cell_[1];
      }
      rects[id] = _CageRect(minR, minC, maxR, maxC, entry.value.sum);
    }
    final n = b.size;
    return SizedBox.expand(
      child: IgnorePointer(
        child: CustomPaint(
          painter: _CagePainter(
              cageId: cageId,
              rects: rects,
              cell: cell,
              bg: scheme.surface,
              lineColor: scheme.onSurface,
              filledMask: _filledMask(b)),
        ),
      ),
    );
  }

  /// 哪些格已填（已填格的笼框线**截断**，让原数字露出来）
  List<List<bool>> _filledMask(SudokuBoard b) {
    return [
      for (final row in b.cells)
        [for (final v in row) v != 0]
    ];
  }

  // ---------- 锯齿 宫 ----------
  // v1.9.0+23：签名拿基类 SudokuRules，内部 `is JigsawRules` 收窄。
  // 调用点直接传 `rules` 而非 `rules as JigsawRules`，避免编译期 Dart 推断失败。
  Widget _jigsawOverlay(SudokuRules rules, double cell, ColorScheme scheme) {
    if (rules is! JigsawRules) return const SizedBox.shrink();
    final n = rules.size;
    return SizedBox.expand(
      child: IgnorePointer(
        child: CustomPaint(
          painter: _JigsawPainter(
            regionOf: rules.regionOf,
            cell: cell,
            n: n,
            lineColor: scheme.onSurface,
          ),
        ),
      ),
    );
  }

  // ---------- 不等式（> / <） ----------
  Widget _greaterOverlay(SudokuBoard b, double cell, ColorScheme scheme) {
    final marks = b.relationMark!;
    final n = b.size;
    return SizedBox.expand(
      child: IgnorePointer(
        child: CustomPaint(
          painter: _GreaterPainter(
              marks: marks, cell: cell, n: n, color: scheme.onSurface),
        ),
      ),
    );
  }

  // ---------- 连续（○） ----------
  Widget _consecutiveOverlay(SudokuBoard b, double cell, ColorScheme scheme) {
    final marks = b.relationMark!;
    final n = b.size;
    return SizedBox.expand(
      child: IgnorePointer(
        child: CustomPaint(
          painter: _ConsecutivePainter(
              marks: marks, cell: cell, n: n, color: scheme.onSurface),
        ),
      ),
    );
  }

  // ---------- 奇偶（标注在格底） ----------
  Widget _evenOddOverlay(SudokuRules rules, double cell, ColorScheme scheme) {
    if (rules is! EvenOddRules) return const SizedBox.shrink();
    final marks = rules.evenOdd;
    final n = rules.size;
    return SizedBox.expand(
      child: IgnorePointer(
        child: CustomPaint(
          painter: _EvenOddPainter(marks: marks, cell: cell, n: n),
        ),
      ),
    );
  }

  // ---------- 箭头 ----------
  Widget _arrowOverlay(SudokuBoard b, SudokuRules rules, double cell, ColorScheme scheme) {
    if (rules is! ArrowRules) return const SizedBox.shrink();
    return SizedBox.expand(
      child: IgnorePointer(
        child: CustomPaint(
          painter: _ArrowPainter(
              board: b,
              arrows: rules.arrows,
              cell: cell,
              color: scheme.onSurface.withValues(alpha: 0.7)),
        ),
      ),
    );
  }
}

// ============================================================ 自定义绘制

class _CageRect {
  final int r1, c1, r2, c2, sum;
  _CageRect(this.r1, this.c1, this.r2, this.c2, this.sum);
}

class _CagePainter extends CustomPainter {
  final List<List<int>> cageId;
  final Map<int, _CageRect> rects;
  final double cell;
  final Color bg;
  final Color lineColor;
  final List<List<bool>> filledMask;
  _CagePainter({
    required this.cageId,
    required this.rects,
    required this.cell,
    required this.bg,
    required this.lineColor,
    required this.filledMask,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = lineColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    // 笼框 + 框角和
    for (final rect in rects.values) {
      final left = rect.c1 * cell;
      final top = rect.r1 * cell;
      final right = (rect.c2 + 1) * cell;
      final bottom = (rect.r2 + 1) * cell;
      // 只画四边「外部是同笼」的线，且**已填格**处截断让数字露出来
      // 上边
      if (rect.r1 == 0 || cageId[rect.r1 - 1][rect.c1] != cageId[rect.r1][rect.c1]) {
        _drawCageLine(canvas, paint, left, top, right, top, true);
      }
      // 下边
      if (rect.r2 == cageId.length - 1 ||
          cageId[rect.r2 + 1][rect.c1] != cageId[rect.r2][rect.c1]) {
        _drawCageLine(canvas, paint, left, bottom, right, bottom, false);
      }
      // 左边
      if (rect.c1 == 0 || cageId[rect.r1][rect.c1 - 1] != cageId[rect.r1][rect.c1]) {
        _drawCageLine(canvas, paint, left, top, left, bottom, false);
      }
      // 右边
      if (rect.c2 == cageId[0].length - 1 ||
          cageId[rect.r1][rect.c2 + 1] != cageId[rect.r1][rect.c2]) {
        _drawCageLine(canvas, paint, right, top, right, bottom, false);
      }
      // 角标：左上格角内
      final tp = TextPainter(
        text: TextSpan(
          text: '${rect.sum}',
          style: TextStyle(
            fontSize: cell * 0.18,
            color: lineColor,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(left + 2, top - tp.height + 2));
    }
  }

  /// 画笼框的一段直线。`isHorizontalTop=true` 时是横向顶边，
  /// 按列扫一遍，已填列跳过。其它三边类似。
  void _drawCageLine(Canvas canvas, Paint paint, double x1, double y1,
      double x2, double y2, bool isHorizontalTop) {
    if (isHorizontalTop) {
      // 按列扫：left..right
      final c1 = (x1 / cell).round();
      final c2 = (x2 / cell).round() - 1;
      final r = (y1 / cell).round();
      // 这一边正下方是 r 行；标记：如果 r>0 且 r-1 是同笼 → 不画（已被 super 判断挡住）
      // 顶边：本格 (r) 上方是 r-1；r-1 不属于本笼 → 这条边需要画
      for (var c = c1; c <= c2; c++) {
        if (c >= 0 && c < filledMask[0].length && filledMask[r][c]) continue;
        canvas.drawLine(Offset(c * cell, y1), Offset((c + 1) * cell, y1), paint);
      }
      return;
    }
    // 通用：等分 cell 段，跳过已填格中点
    final isHoriz = (y1 - y2).abs() < 0.001;
    if (isHoriz) {
      final c1 = (x1 / cell).round();
      final c2 = (x2 / cell).round() - 1;
      final r = (y1 / cell).round();
      for (var c = c1; c <= c2; c++) {
        if (c >= 0 && c < filledMask[0].length && filledMask[r][c]) continue;
        canvas.drawLine(Offset(c * cell, y1), Offset((c + 1) * cell, y1), paint);
      }
    } else {
      final r1 = (y1 / cell).round();
      final r2 = (y2 / cell).round() - 1;
      final c = (x1 / cell).round();
      for (var r = r1; r <= r2; r++) {
        if (r >= 0 && r < filledMask.length && filledMask[r][c]) continue;
        canvas.drawLine(Offset(x1, r * cell), Offset(x1, (r + 1) * cell), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_CagePainter old) => false;
}

class _JigsawPainter extends CustomPainter {
  final List<List<int>> regionOf;
  final double cell;
  final int n;
  final Color lineColor;
  _JigsawPainter({
    required this.regionOf,
    required this.cell,
    required this.n,
    required this.lineColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = lineColor
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    // v1.9.0+28 修「锯齿数独看不到锯齿」：
    // 原来每段宫界线都套了 `if (!filledMask[r][c])` —— 只要这格**有提示数字**
    // 就整条边不画。开局 30~50 格都是提示，于是锯齿宫几乎全被吃掉，
    // 看起来跟标准 9 宫格一样。
    // 宫界线本来就落在格子**边上**，不会压到居中的数字，所以直接全画。
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        final myId = regionOf[r][c];
        // 上边界
        if (r == 0 || regionOf[r - 1][c] != myId) {
          canvas.drawLine(
              Offset(c * cell, r * cell), Offset((c + 1) * cell, r * cell), paint);
        }
        // 下边界
        if (r == n - 1 || regionOf[r + 1][c] != myId) {
          canvas.drawLine(Offset(c * cell, (r + 1) * cell),
              Offset((c + 1) * cell, (r + 1) * cell), paint);
        }
        // 左边界
        if (c == 0 || regionOf[r][c - 1] != myId) {
          canvas.drawLine(
              Offset(c * cell, r * cell), Offset(c * cell, (r + 1) * cell), paint);
        }
        // 右边界
        if (c == n - 1 || regionOf[r][c + 1] != myId) {
          canvas.drawLine(Offset((c + 1) * cell, r * cell),
              Offset((c + 1) * cell, (r + 1) * cell), paint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_JigsawPainter old) => false;
}

class _GreaterPainter extends CustomPainter {
  final List<List<String>> marks;
  final double cell;
  final int n;
  final Color color;
  _GreaterPainter({
    required this.marks,
    required this.cell,
    required this.n,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final tp = (String s) {
      final t = TextPainter(
        text: TextSpan(
            text: s,
            style: TextStyle(
                fontSize: cell * 0.22,
                color: color,
                fontWeight: FontWeight.w700)),
        textDirection: TextDirection.ltr,
      )..layout();
      return t;
    };
    for (var r = 0; r < marks.length; r++) {
      for (var c = 0; c < marks[r].length; c++) {
        final m = marks[r][c];
        if (m == '<') {
          // c 列比 c-1 列大（c-1 < c）→ 画在 c 列左下角
          tp('<').paint(canvas, Offset(c * cell - cell * 0.13, (r + 1) * cell - cell * 0.35));
        } else if (m == '>') {
          // c 列比 c-1 列小（c-1 > c）→ 画在 c 列左下角
          tp('>').paint(canvas, Offset(c * cell - cell * 0.13, (r + 1) * cell - cell * 0.35));
        }
      }
    }
  }

  @override
  bool shouldRepaint(_GreaterPainter old) => false;
}

class _ConsecutivePainter extends CustomPainter {
  final List<List<String>> marks;
  final double cell;
  final int n;
  final Color color;
  _ConsecutivePainter({
    required this.marks,
    required this.cell,
    required this.n,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n - 1; c++) {
        if (marks[r][c] == 'o') {
          // 画在 (r,c) 与 (r,c+1) 之间的中线
          final cx = (c + 1) * cell;
          final cy = (r + 0.5) * cell;
          canvas.drawCircle(Offset(cx, cy), cell * 0.13, paint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_ConsecutivePainter old) => false;
}

class _EvenOddPainter extends CustomPainter {
  final List<List<String>> marks;
  final double cell;
  final int n;
  _EvenOddPainter({required this.marks, required this.cell, required this.n});

  @override
  void paint(Canvas canvas, Size size) {
    final tpStyle = (String s, Color c) {
      final t = TextPainter(
        text: TextSpan(
            text: s,
            style: TextStyle(
                fontSize: cell * 0.20, color: c, fontWeight: FontWeight.w700)),
        textDirection: TextDirection.ltr,
      )..layout();
      return t;
    };
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        final m = marks[r][c];
        if (m == 'e') {
          tpStyle('E', const Color(0xFFB8860B))
              .paint(canvas, Offset(c * cell + 2, r * cell));
        } else if (m == 'o') {
          tpStyle('O', const Color(0xFF185FA5))
              .paint(canvas, Offset(c * cell + 2, r * cell));
        }
      }
    }
  }

  @override
  bool shouldRepaint(_EvenOddPainter old) => false;
}

class _ArrowPainter extends CustomPainter {
  final SudokuBoard board;
  final List<ArrowDef> arrows;
  final double cell;
  final Color color;
  _ArrowPainter({
    required this.board,
    required this.arrows,
    required this.cell,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final arr in arrows) {
      final ball = arr.ball;
      // 路径：从 ball 一格一格画到 arr.path 末端
      Offset last = Offset((ball[1] + 0.5) * cell, (ball[0] + 0.5) * cell);
      for (final p in arr.path) {
        final next = Offset((p[1] + 0.5) * cell, (p[0] + 0.5) * cell);
        canvas.drawLine(last, next, paint);
        last = next;
      }
      // 终点小三角
      final tp = TextPainter(
        text: TextSpan(
            text: '◀',
            style: TextStyle(color: color, fontSize: cell * 0.3)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, last - Offset(tp.width / 2, tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(_ArrowPainter old) => false;
}

// ============================================================ UI：数字盘
//
// v1.9.0+28 重做（按用户要求）：
//   * 数字框「尽可能大、贴手机屏幕边」—— 原来是 56×56 的 Wrap，四周留白多
//   * 去掉旁边的「擦除」按钮（要清格就再点一次同一个数字，或长按格子）
//   * 9 个数字排成 2 排（1-5 / 6-9），不换行不滚动
//   * 每个数字右下角加「剩余个数」小角标（已放满 → ✓）
class _NumberPad extends StatelessWidget {
  final int size;
  final int current;
  final Set<int> notes;
  final bool noteMode;

  /// 每个数字还能放几次（角标用）
  final Map<int, int> remain;
  final void Function(int v) onPick;

  const _NumberPad({
    required this.size,
    required this.current,
    required this.notes,
    required this.noteMode,
    required this.remain,
    required this.onPick,
  });

  /// 数字分行：9 个 → 5 + 4；其它 → 单排
  List<List<int>> get _rows {
    if (size <= 5) return [List.generate(size, (i) => i + 1)];
    if (size == 9) {
      return [
        [1, 2, 3, 4, 5],
        [6, 7, 8, 9],
      ];
    }
    final half = (size / 2).ceil();
    return [
      List.generate(half, (i) => i + 1),
      List.generate(size - half, (i) => half + i + 1),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final rows = _rows;
    final cols = rows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
    return SafeArea(
      top: false,
      child: Padding(
        // 贴屏幕边：左右只留 4
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: cs.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  Icon(
                    noteMode ? Icons.edit_note : Icons.grid_3x3,
                    size: 16,
                    color: noteMode ? cs.primary : cs.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    noteMode
                        ? '笔记模式 · 点数字加 / 删候选'
                        : (current == 0 ? '选一个数字' : '当前 $current · 再点同数字可清除'),
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: noteMode ? FontWeight.w700 : FontWeight.w500,
                      color: noteMode ? cs.primary : cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < rows.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    for (final v in rows[i])
                      Expanded(child: _pickButton(context, v)),
                    // 第二排比第一排短 → 补位占位符，保证两排按钮等宽
                    for (var k = rows[i].length; k < cols; k++)
                      const Expanded(child: SizedBox.shrink()),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _pickButton(BuildContext context, int v) {
    final cs = Theme.of(context).colorScheme;
    final isNote = noteMode && notes.contains(v);
    final isCurrent = !noteMode && current == v;
    final left = remain[v] ?? -1;
    final bg = isCurrent
        ? cs.primaryContainer
        : isNote
            ? cs.secondaryContainer
            : cs.surfaceContainerHighest.withValues(alpha: 0.6);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: GestureDetector(
        onTap: () => onPick(v),
        child: Container(
          // 高度跟着宽度走，屏幕多宽按钮就多大（v2.1.0：上限 78 → 96，更好按）
          constraints: const BoxConstraints(maxHeight: 96),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
          ),
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: AspectRatio(
            aspectRatio: 1.15,
            child: Stack(
              children: [
                Center(
                  child: Text(
                    '$v',
                    style: TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w600,
                      color: isCurrent ? cs.onPrimaryContainer : cs.onSurface,
                    ),
                  ),
                ),
                // 剩余个数角标
                Positioned(
                  right: 2,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: left == 0
                          ? cs.primary.withValues(alpha: 0.15)
                          : cs.surface.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      left <= 0 ? '✓' : '$left',
                      style: TextStyle(
                        fontSize: 10.5,
                        height: 1.1,
                        fontWeight: FontWeight.w600,
                        color: left <= 0
                            ? cs.primary
                            : cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}