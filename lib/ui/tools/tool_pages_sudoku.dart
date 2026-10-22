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
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../data/local/pref_store.dart';

import 'tool_pages.dart'; // ToolScaffold

// ============================================================ 类型

/// 数独类型枚举。
///
/// v2.3.2 按用户要求大改一轮：
///   * 「标准数独」改名「九宫格」；
///   * 「对角数独 X」改名「对角线数独」（盘面上直接画出两条对角线）；
///   * 「不等式数独」改名「六宫格比比数独」，排到第三位；
///   * 删掉「超数独」「连续数独」「箭头数独」；
///   * 每个类型带一句 [rule]（玩法说明），显示在棋盘下面。
///
/// 排序 = 下拉框顺序：入门两档 → 比比 → 九宫格 → 异形。
enum SudokuType {
  mini4('四宫格', '4×4 · 2×2 宫 · 入门',
      '每行、每列、每个 2×2 宫里，1~4 都恰好出现一次。'),
  mini6('六宫格', '6×6 · 2×3 宫 · 入门',
      '每行、每列、每个 2×3 宫里，1~6 都恰好出现一次。'),
  greater('六宫格比比数独', '6×6 · 相邻格按「>」「<」比大小',
      '在六宫格规则之上，相邻格之间标了「>」「<」：符号开口那边是大数，'
          '尖角那边是小数，填的数必须符合两边的大小关系。'),
  standard('九宫格', '9×9 · 3×3 宫 · 经典',
      '每行、每列、每个 3×3 宫里，1~9 都恰好出现一次。'),
  diagonal('对角线数独', '9×9 + 两条对角线也不重复',
      '在九宫格规则之上，两条蓝色对角线上的 9 个数字也必须互不重复。'),
  jigsaw('锯齿数独', '9×9 · 宫是不规则锯齿形状',
      '每行、每列照常 1~9 不重复；但「宫」变成了 9 块不规则的锯齿——'
          '同一种底色 + 粗边线围住的就是一个宫。'),
  killer('杀手数独', '9×9 + 虚线笼，笼内之和 = 角标',
      '在九宫格规则之上，虚线框（笼）把若干格圈在一起：笼内数字不能重复，'
          '且笼内所有数字之和 = 左上角标的小数字。'),
  evenodd('奇偶数独', '9×9 · 部分格限定奇偶',
      '在九宫格规则之上，标「O」的格必须填奇数，标「E」的格必须填偶数。');

  final String label;
  final String hint;

  /// 棋盘下面显示给玩家的玩法说明。
  final String rule;
  const SudokuType(this.label, this.hint, this.rule);

  /// 棋盘边长。四宫格 4、六宫格 / 比比数独 6，其余 9。
  int get size {
    switch (this) {
      case SudokuType.mini4:
        return 4;
      case SudokuType.mini6:
      case SudokuType.greater:
        return 6;
      default:
        return 9;
    }
  }

  /// v2.3.1：所有类型都是正方形盘。
  int get height => size;
}

/// 难度。决定「挖多少格」—— 按格子总数的比例算，4/6/9 宫格才都合理
/// （原来写死挖 56 格，4×4 一共才 16 格，直接挖穿）。
///
/// v2.3.2：地狱 0.72 → 0.78（用户反馈「还不够难」），并且挖洞算法换成
/// 「逐格验证法」（见 `SudokuRules.digHoles`），能挖到该算法下的极限。
enum SudokuDifficulty {
  easy('简单', 0.37),
  medium('中等', 0.50),
  hard('困难', 0.63),
  hell('地狱', 0.78);

  final String label;

  /// 挖掉的比例（0~1）。
  final double ratio;
  const SudokuDifficulty(this.label, this.ratio);

  /// 这个难度在这个尺寸下该挖多少格。
  int holesFor(int cells) => (cells * ratio).round().clamp(1, cells - 2);
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

  /// 3×3 宫的行数 / 列数。4×4 是 2×2，6×6 是 2 行 × 3 列，9×9 是 3×3。
  int get boxRows => size % 3 == 0 && size != 6 ? 3 : 2;
  int get boxCols => size == 6 ? 3 : (size == 4 ? 2 : 3);

  bool isLegal(SudokuBoard b, int r, int c, int v);

  /// 行 / 列 / 宫**之外**的额外约束（对角线、超数独窗口、笼、奇偶、
  /// 连续、箭头、不等式）。
  ///
  /// v2.3.1 新增：快速求解器自己用位掩码处理行 / 列 / 宫，
  /// 剩下的约束统一走这个钩子，这样每种异形只要写十几行就能接进求解器，
  /// 不用各写一套回溯 —— 之前锯齿数独一点就卡死，就是因为「出题」那条路
  /// 根本没把锯齿宫算进去（用标准 3×3 宫的 `isLegal` 一份份试）。
  bool extraOk(SudokuBoard b, int r, int c, int v) => true;

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
  /// `holes` = N×N - 提示数；地狱难度额外要求解唯一。
  ///
  /// v2.3.2：挖洞算法拆成两条路 ——
  ///   * 普通难度（老做法）：按随机顺序一口气挖掉 holes 格，简单快；
  ///   * 地狱难度（新做法，「逐格验证法」）：把全部格子按随机顺序排好，
  ///     一格一格**试着挖**——挖掉后用 `_FastSolver` 数解数，解不唯一就
  ///     把这格放回去。这样每一步都保持「唯一解」，能一路挖到这个顺序下
  ///     挖不动的极限。旧做法「先全挖再补回 8 格」经常留下明显偏简单的盘，
  ///     用户反馈「地狱还不够难」就是这个原因。
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

    if (requireUnique) {
      // ---------- 地狱：逐格验证法 ----------
      final cells = <List<int>>[];
      for (var r = 0; r < n; r++) {
        for (var c = 0; c < n; c++) {
          cells.add([r, c]);
        }
      }
      cells.shuffle(rng);
      // 求解器复用一个（countSolutions 每次会自己重新 _load）
      final solver = _FastSolver(this, rng, nodeLimit: 40000);
      var dug = 0;
      for (final cell in cells) {
        if (dug >= holes) break;
        final r = cell[0], c = cell[1];
        final v = puzzle.cells[r][c];
        if (v == 0) continue;
        puzzle.cells[r][c] = 0;
        puzzle.notes[r][c].clear();
        if (solver.countSolutions(puzzle, cap: 2) != 1) {
          // 挖了它解就不唯一了 → 放回去
          puzzle.cells[r][c] = v;
        } else {
          dug++;
        }
      }
      for (var r = 0; r < n; r++) {
        for (var c = 0; c < n; c++) {
          puzzle.fixed[r][c] = puzzle.cells[r][c] != 0;
        }
      }
      return puzzle;
    }

    // ---------- 普通/中等/困难：一口气挖 ----------
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

  // 宫大小：4×4 → 2×2；6×6 → 2 行 × 3 列；9×9 → 3×3
  int _boxRows() => boxRows;
  int _boxCols() => boxCols;

  int _boxR(int r) => (r ~/ _boxRows()) * _boxRows();
  int _boxC(int c) => (c ~/ _boxCols()) * _boxCols();

  @override
  SudokuBoard generateFull(math.Random rng) {
    // v2.3.1：改用带位掩码 + MRV 的求解器（见 `_FastSolver`）。
    // 旧实现「第一行洗牌 + 顺序回溯」在 9×9 上勉强够用，但四种异形
    // （锯齿 / 超 / 奇偶 / 箭头）都得靠它，一旦约束变紧就会退化成
    // 几十万次全盘扫描 —— 用户看到的「一点就卡死」就是这么来的。
    for (var attempt = 0; attempt < 6; attempt++) {
      final board = SudokuBoard.empty(size);
      if (_FastSolver(this, rng).solve(board) && isValidSolution(board)) {
        return board;
      }
    }
    // 兜底：用拉丁方公式直接铺一个（对标准 / 对角都成立）
    final board = SudokuBoard.empty(size);
    final br = boxRows;
    final shift = size % br == 0 ? br : 3;
    for (var r = 0; r < size; r++) {
      for (var c = 0; c < size; c++) {
        board.cells[r][c] = (r * shift + r ~/ br + c) % size + 1;
      }
    }
    return board;
  }
}

/// 对角 X：行 / 列 / 宫 + 两条主对角线
class DiagonalRules extends StandardRules {
  DiagonalRules(super.type);
  @override
  bool isLegal(SudokuBoard b, int r, int c, int v) {
    if (!super.isLegal(b, r, c, v)) return false;
    return extraOk(b, r, c, v);
  }

  @override
  bool extraOk(SudokuBoard b, int r, int c, int v) {
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
    // 宫 = 自己的锯齿分区，逐个扫同区格子
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

  /// 锯齿的宫界是随机的，快速求解器直接读 [regionOf]（见 _FastSolver），
  /// 所以这里不需要额外的 extraOk。

}

/// 杀手：每笼数字不重且和 = 笼和。
class KillerRules extends StandardRules {
  KillerRules(super.type);

  @override
  bool isLegal(SudokuBoard b, int r, int c, int v) {
    if (!super.isLegal(b, r, c, v)) return false;
    return extraOk(b, r, c, v);
  }

  @override
  bool extraOk(SudokuBoard b, int r, int c, int v) {
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
          // v2.3.1：笼内数字**必须互不相同**（规则要求），
          // 否则「正确解」本身就会违反规则，用户照着答案填也报错。
          final nv = full.cells[nr][nc];
          if (cellsList.any((c) => full.cells[c[0]][c[1]] == nv)) continue;
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

/// 不等式：相邻格按「>」「<」标记大小关系。
/// v2.3.1 起是 **6×6**（原来写「9 列 × 6 行」，但棋盘模型是 N×N，
/// 实际填了 9 行却只显示 6 行 —— 显示和判题全错）。
/// 只做**行内**不等式；列内不加（混合算法太重）。
class GreaterRules extends StandardRules {
  GreaterRules(super.type);

  @override
  bool isLegal(SudokuBoard b, int r, int c, int v) {
    if (!super.isLegal(b, r, c, v)) return false;
    return extraOk(b, r, c, v);
  }

  @override
  bool extraOk(SudokuBoard b, int r, int c, int v) {
    // marks[r][c] 表示「(r,c-1) 与 (r,c) 的关系」：'<' 左边小，'>' 左边大
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
    return extraOk(b, r, c, v);
  }

  @override
  bool extraOk(SudokuBoard b, int r, int c, int v) {
    final mark = evenOdd[r][c];
    if (mark == 'e' && v.isOdd) return false;
    if (mark == 'o' && v.isEven) return false;
    return true;
  }

  @override
  SudokuBoard generateFull(math.Random rng) {
    final full = super.generateFull(rng);
    // v2.3.1：标记必须**按解的真实奇偶**来撒。
    // 原来是随机撒 'e'/'o'，那个解自己都可能违反 —— 用户照着答案填反而报错。
    final n = full.size;
    final marks = List.generate(n, (_) => List.filled(n, ''));
    final cells = <List<int>>[];
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        cells.add([r, c]);
      }
    }
    cells.shuffle(rng);
    final toMark = math.min(n + 3, cells.length);
    for (var i = 0; i < toMark; i++) {
      final r = cells[i][0], c = cells[i][1];
      marks[r][c] = full.cells[r][c].isEven ? 'e' : 'o';
    }
    evenOdd
      ..clear()
      ..addAll(marks);
    return full;
  }
}

// ============================================================ 引擎：解算器

/// 快速求解器：**位掩码 + MRV**（每一步先填「可选项最少」的空格）。
///
/// 为什么把原来那套「顺序回溯 + 每次调 isLegal」换掉（v2.3.1）：
///   * `isLegal` 每判一格要扫 27 个格子，锯齿数独还要扫满 81 个；
///   * 顺序回溯在约束变紧时会退化成指数爆炸 —— 用户点「锯齿数独」
///     直接卡死，就是因为那个随机宫界可能根本无解，它却会一直试下去。
///
/// 现在候选集用位运算一次算出来，先填最没得选的格子，并且有**节点上限**；
/// 超限就认输返回 false，外层换一种宫界重新来（见 `_newGame`）。
class _FastSolver {
  _FastSolver(this.rules, this.rng, {this.nodeLimit = 60000})
      : n = rules.size,
        region = _regionsOf(rules),
        _rowMask = List<int>.filled(rules.size, 0),
        _colMask = List<int>.filled(rules.size, 0),
        _regMask = List<int>.filled(rules.size, 0);

  final SudokuRules rules;
  final math.Random rng;
  final int n;

  /// `region[r][c]` = 这一格属于哪个宫（0..n-1）。锯齿读它自己的分区，
  /// 其它按 boxRows × boxCols 切。
  final List<List<int>> region;
  final int nodeLimit;

  int _nodes = 0;

  final List<int> _rowMask;
  final List<int> _colMask;
  final List<int> _regMask;

  static List<List<int>> _regionsOf(SudokuRules rules) {
    if (rules is JigsawRules) return rules.regionOf;
    final n = rules.size;
    final br = rules.boxRows;
    final bc = rules.boxCols;
    final perRow = n ~/ bc;
    return List.generate(
        n, (r) => List.generate(n, (c) => (r ~/ br) * perRow + c ~/ bc));
  }

  int get _full => (1 << n) - 1;

  List<int> get _row => _rowMask;
  List<int> get _col => _colMask;
  List<int> get _reg => _regMask;

  /// 把棋盘上已有的数字装进位掩码。有冲突返回 false。
  bool _load(SudokuBoard b) {
    for (var i = 0; i < n; i++) {
      _rowMask[i] = 0;
      _colMask[i] = 0;
      _regMask[i] = 0;
    }
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        final v = b.cells[r][c];
        if (v == 0) continue;
        final bit = 1 << (v - 1);
        final g = region[r][c];
        if ((_row[r] & bit) != 0 ||
            (_col[c] & bit) != 0 ||
            (_reg[g] & bit) != 0) {
          return false;
        }
        _row[r] |= bit;
        _col[c] |= bit;
        _reg[g] |= bit;
      }
    }
    return true;
  }

  /// 把棋盘填满（原地改 [b]）。失败返回 false（b 可能被改了一半，调用方别用）。
  bool solve(SudokuBoard b) {
    if (!_load(b)) return false;
    _nodes = 0;
    return _search(b);
  }

  bool _search(SudokuBoard b) {
    if (++_nodes > nodeLimit) return false;

    // ---- MRV：找候选最少的那一格 ----
    var bestR = -1, bestC = -1, bestMask = 0, bestCount = 99;
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        if (b.cells[r][c] != 0) continue;
        final avail =
            _full & ~(_row[r] | _col[c] | _reg[region[r][c]]);
        final cnt = _bitCount(avail);
        if (cnt == 0) return false; // 这一格没得填 → 这条路走死了
        if (cnt < bestCount) {
          bestCount = cnt;
          bestR = r;
          bestC = c;
          bestMask = avail;
          if (cnt == 1) break;
        }
      }
      if (bestCount == 1) break;
    }
    if (bestR < 0) return true; // 没有空格 = 填满了

    final cand = <int>[];
    for (var v = 1; v <= n; v++) {
      if ((bestMask & (1 << (v - 1))) != 0) cand.add(v);
    }
    cand.shuffle(rng); // 每次换顺序 → 出题不会永远一个解法

    final g = region[bestR][bestC];
    for (final v in cand) {
      if (!rules.extraOk(b, bestR, bestC, v)) continue;
      final bit = 1 << (v - 1);
      b.cells[bestR][bestC] = v;
      _row[bestR] |= bit;
      _col[bestC] |= bit;
      _reg[g] |= bit;
      if (_search(b)) return true;
      b.cells[bestR][bestC] = 0;
      _row[bestR] &= ~bit;
      _col[bestC] &= ~bit;
      _reg[g] &= ~bit;
      if (_nodes > nodeLimit) return false;
    }
    return false;
  }

  /// 数解数（找到 [cap] 个就停）。地狱难度用这个验唯一。
  int countSolutions(SudokuBoard b, {int cap = 2}) {
    if (!_load(b)) return 0;
    _nodes = 0;
    _count = 0;
    _countSearch(b, cap);
    return _count;
  }

  int _count = 0;

  void _countSearch(SudokuBoard b, int cap) {
    if (_count >= cap || _nodes > nodeLimit) return;
    _nodes++;

    var bestR = -1, bestC = -1, bestMask = 0, bestCount = 99;
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        if (b.cells[r][c] != 0) continue;
        final avail = _full & ~(_row[r] | _col[c] | _reg[region[r][c]]);
        final cnt = _bitCount(avail);
        if (cnt == 0) return;
        if (cnt < bestCount) {
          bestCount = cnt;
          bestR = r;
          bestC = c;
          bestMask = avail;
          if (cnt == 1) break;
        }
      }
      if (bestCount == 1) break;
    }
    if (bestR < 0) {
      _count++;
      return;
    }

    final g = region[bestR][bestC];
    for (var v = 1; v <= n && _count < cap && _nodes <= nodeLimit; v++) {
      if ((bestMask & (1 << (v - 1))) == 0) continue;
      if (!rules.extraOk(b, bestR, bestC, v)) continue;
      final bit = 1 << (v - 1);
      b.cells[bestR][bestC] = v;
      _row[bestR] |= bit;
      _col[bestC] |= bit;
      _reg[g] |= bit;
      _countSearch(b, cap);
      b.cells[bestR][bestC] = 0;
      _row[bestR] &= ~bit;
      _col[bestC] &= ~bit;
      _reg[g] &= ~bit;
    }
  }

  static int _bitCount(int v) {
    var c = 0;
    while (v != 0) {
      v &= v - 1;
      c++;
    }
    return c;
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

  /// 本局用了几次「提示」（v2.3.5：提示改成真的填数字了，记一下次数）
  int _hintUsed = 0;

  /// 「提示」随机挑格用的随机源。
  /// 不能每次 new 一个 —— 连续点两下时间戳相同，取到的格子会一模一样。
  final math.Random _hintRng = math.Random();

  /// 当前选中的格子（-1 = 没选）。数字盘只往选中的格子里填。
  int _selR = -1;
  int _selC = -1;

  /// 底部状态栏右边那句提示（原来全用 toast，现在一屏放得下了）
  String _msg = '';

  /// 用时每秒走一格
  Timer? _tick;

  /// v1.9.0+28：「校验」标出来的错格（key = "r-c"），用户落子后清空
  Set<String> _checkedWrong = {};

  /// 出题序号：每次出题 +1。异步生成结束时如果对不上，说明用户已经
  /// 换了题型 / 点了新题，这一份结果直接丢掉。
  int _genSeq = 0;

  @override
  void initState() {
    super.initState();
    _restore();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _board == null) return;
      setState(() {}); // 只为刷新「用时」
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
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
    // v2.3.0：进页面直接给一道题（跟网页版一致，不再先停在选题页）
    if (mounted && _board == null) _newGame();
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
    // 用序号区分「这是第几次出题」：切换题型 / 点新题时旧的生成还在跑，
    // 它算完时对不上号就自己丢掉，不会把新结果盖掉。
    final seq = ++_genSeq;
    setState(() => _busy = true);
    // 出题是同步计算，会卡住主线程 —— 先让「正在生成…」这一帧画出来，
    // 否则用户看到的是纯空白（v2.3.0 单屏版尤其明显）。
    await Future<void>.delayed(const Duration(milliseconds: 24));
    if (!mounted || seq != _genSeq) return;
    final rng = math.Random();

    late SudokuRules rules;
    late SudokuBoard full;

    switch (_type) {
      case SudokuType.mini4:
      case SudokuType.mini6:
      case SudokuType.standard:
        rules = StandardRules(_type);
        full = rules.generateFull(rng);
        break;
      case SudokuType.diagonal:
        rules = DiagonalRules(_type);
        full = rules.generateFull(rng);
        break;
      case SudokuType.jigsaw:
        // v2.3.6（用户第 1 条）：不再现场随机切宫。
        //   * 「种子往外涨」出的随机形状大多**无解**，失败就退回标准宫；
        //   * 「交换相邻边界格」在标准 3×3 宫上**永远换不动** —— 互换后
        //     两边新得的那一格只跟被换走的那格相邻，连通性检查必然失败，
        //     交换次数恒为 0，等于原样返回标准宫。
        // 两种路最后都落到「普通九宫格」，玩家看到的就是「只有宫格涂色」。
        //
        // 现在直接用内置的 12 套锯齿布局（见 `_kJigsawTemplates`），
        // 每套都带一个已验证的合法解，只做对称变换 + 重排，**不再求解**。
        final built = _buildJigsaw(rng);
        rules = JigsawRules(_type, built.$1);
        full = built.$2;
        if (!rules.isValidSolution(full)) {
          // 自检兜底：正常走不到这里（12 套模板都离线验证过）
          rules = StandardRules(SudokuType.jigsaw);
          full = rules.generateFull(rng);
        }
        break;
      case SudokuType.killer:
        rules = KillerRules(_type);
        full = rules.generateFull(rng);
        break;
      case SudokuType.greater:
        rules = GreaterRules(_type);
        full = rules.generateFull(rng);
        full.relationMark = _makeGreaterMarks(full, rng);
        break;
      case SudokuType.evenodd:
        final rulesEO = EvenOddRules(_type,
            List.generate(_type.size, (_) => List.filled(_type.size, '')));
        full = rulesEO.generateFull(rng);
        rules = rulesEO;
        break;
    }

    final n = _type.size;
    final dig = rules.digHoles(
      full,
      _diff.holesFor(n * n),
      rng,
      requireUnique: _diff == SudokuDifficulty.hell,
    );

    if (!mounted || seq != _genSeq) return;
    setState(() {
      _rules = rules;
      _solution = full;
      _board = dig;
      _errCount = 0;
      _hintUsed = 0;
      _showHint = false;
      _busy = false;
      _checkedWrong = {};
      _undoStack.clear();
      _startedAt = DateTime.now();
      _selR = -1;
      _selC = -1;
      _msg = '点一格，再点下面的数字';
    });
    _save();
  }

  /// 不等式：按**解的真实大小关系**撒「<」「>」。
  ///
  /// v2.3.1 修：原来是随机撒符号，跟解毫无关系 —— 用户照正确答案填，
  /// 反而被标红。现在只标「解里确实满足」的那些边，随机决定标或不标。
  List<List<String>> _makeGreaterMarks(SudokuBoard full, math.Random rng) {
    final n = full.size;
    final marks = List.generate(n, (_) => List.filled(n, ''));
    for (var r = 0; r < n; r++) {
      for (var c = 1; c < n; c++) {
        if (rng.nextDouble() > 0.6) continue;
        final a = full.cells[r][c - 1];
        final b = full.cells[r][c];
        if (a == b) continue;
        marks[r][c] = a < b ? '<' : '>';
      }
    }
    return marks;
  }

  /// 点格子 = 选中（v2.3.0 起不再弹数字盘，数字盘常驻在棋盘下面）。
  ///
  /// 提示格也允许选中 —— 选中后会点亮同行 / 同列 / 同宫，看得清数字分布；
  /// 真要往里填的时候会在 [_onPick] 里拦一句「这格是提示」。
  void _onCellTap(int r, int c) {
    if (_board == null) return;
    setState(() {
      _selR = r;
      _selC = c;
      _msg = '';
    });
  }

  /// 数字盘按下一个数字
  void _onPick(int v) {
    final b = _board;
    if (b == null) return;
    if (_selR < 0 || _selC < 0) {
      setState(() => _msg = '先在盘面上点一格');
      return;
    }
    if (b.fixed[_selR][_selC]) {
      setState(() => _msg = '这格是题目给的提示，不能改');
      return;
    }
    _applyNumber(_selR, _selC, v);
  }

  /// 每个数字在整个盘里该出现几次 = 边长（每行/每列各一次）。
  int get _perNumber => _board?.size ?? _type.size;

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
        _msg = '笔记：本格候选 $v';
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
        _msg = '和同行 / 同列 / 同宫的数字撞了';
      });
      return;
    }
    setState(() {
      b.cells[r][c] = v;
      // 落子后这格的笔记没用了（原来不清，会跟数字叠在一起）
      b.notes[r][c].clear();
      _checkedWrong = {};
      _msg = '';
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

  /// 提示（v2.3.5 重做 —— 以前这个按钮只是把空格染个淡色，用户说「没有作用」）。
  ///
  /// 现在的行为按用户原话：
  ///   * **选中了某一格**（空着或填错了）→ 直接把这一格的正确数字填进去；
  ///   * **没选格**（或选中的格已经填对 / 是题面提示格）→ 在所有还没填对的
  ///     格子里**随机挑一个**填上。
  ///
  /// 走 [_pushUndo]，所以提示填的数字也能撤销；不影响错误计数
  /// （提示不是"答错"），只单独记 [_hintUsed]。
  void _giveHint() {
    final b = _board;
    final s = _solution;
    if (b == null || s == null) return;

    var r = _selR;
    var c = _selC;
    // 选中的格子能直接用吗？（不能是题面提示格，也不能已经填对）
    final canUseSel =
        r >= 0 && c >= 0 && !b.fixed[r][c] && b.cells[r][c] != s.cells[r][c];

    if (!canUseSel) {
      // 收集所有「还能提示」的格子：非题面、当前值和正确解不一致
      final pool = <List<int>>[];
      for (var rr = 0; rr < b.size; rr++) {
        for (var cc = 0; cc < b.size; cc++) {
          if (b.fixed[rr][cc]) continue;
          if (b.cells[rr][cc] == s.cells[rr][cc]) continue;
          pool.add([rr, cc]);
        }
      }
      if (pool.isEmpty) {
        setState(() => _msg = '已经全填对了，用不着提示');
        return;
      }
      final pick = pool[_hintRng.nextInt(pool.length)];
      r = pick[0];
      c = pick[1];
    }

    final v = s.cells[r][c];
    _pushUndo(r, c);
    HapticFeedback.selectionClick();
    setState(() {
      b.cells[r][c] = v;
      b.notes[r][c].clear();
      _selR = r;
      _selC = c;
      _hintUsed++;
      _checkedWrong = {};
      _msg = '提示：第 ${r + 1} 行第 ${c + 1} 列 = $v（共提示 $_hintUsed 次）';
    });
    // 按选中格提示 / 随机提示，填数走的是同一条路径
    if (_rules != null && _rules!.isComplete(b)) _finish();
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
    final b = _board;
    final cs = Theme.of(context).colorScheme;
    return ToolScaffold(
      title: '数独练习',
      subtitle: b == null
          ? '正在出题…'
          : '${_type.label} · ${_diff.label} · 错误 $_errCount',
      child: Column(
        children: [
          _topControls(),
          _toolbar(),
          Expanded(child: _boardArea()),
          // v2.3.2：异形数独的玩法说明（用户要求「下面要给文字说明」）。
          // 放在棋盘和数字盘之间，两行封顶。
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 2, 14, 0),
            child: Text(
              _type.rule,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                height: 1.35,
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
          _pad(),
          _statusBar(),
        ],
      ),
    );
  }

  // ---------- 顶部：题型 / 难度 / 新题 ----------
  //
  // v2.3.0：按用户发的 HTML 版重做 —— **所有东西都在一屏里**。
  // 原来是「先选题型页 → 再进棋盘」，绕一层；现在题型、难度、新题、
  // 五个操作按钮、棋盘、数字盘、用时全部同屏，跟网页版一致。
  Widget _topControls() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
      child: Row(
        children: [
          Expanded(
            child: _selectBox<SudokuType>(
              icon: Icons.grid_3x3,
              value: _type,
              items: SudokuType.values,
              label: (t) => t.label,
              onChanged: (t) {
                if (t == null || t == _type) return;
                setState(() {
                  _type = t;
                  _board = null;
                  _solution = null;
                });
                _newGame();
              },
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: _selectBox<SudokuDifficulty>(
              icon: Icons.speed,
              value: _diff,
              items: SudokuDifficulty.values,
              label: (d) => d.label,
              onChanged: (d) {
                if (d == null || d == _diff) return;
                setState(() {
                  _diff = d;
                  _board = null;
                  _solution = null;
                });
                _newGame();
              },
            ),
          ),
          const SizedBox(width: 6),
          FilledButton.tonalIcon(
            onPressed: _busy ? null : _newGame,
            icon: const Icon(Icons.refresh, size: 17),
            label: const Text('新题'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: const Size(0, 40),
              visualDensity: VisualDensity.compact,
              textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _selectBox<T>({
    required IconData icon,
    required T value,
    required List<T> items,
    required String Function(T) label,
    required ValueChanged<T?> onChanged,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      // 不写死高度：DropdownButton 自己要 40 出头，写死 40 会顶出黄条
      padding: const EdgeInsets.only(left: 8, right: 4),
      decoration: BoxDecoration(
        border: Border.all(color: cs.outlineVariant),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        children: [
          Icon(icon, size: 15, color: cs.onSurfaceVariant),
          const SizedBox(width: 5),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<T>(
                value: value,
                isExpanded: true,
                isDense: true,
                borderRadius: BorderRadius.circular(10),
                // 字号写死，避免跟着系统字体放大把 40 高的框撑破
                style: TextStyle(fontSize: 13, color: cs.onSurface),
                items: [
                  for (final t in items)
                    DropdownMenuItem<T>(
                      value: t,
                      child: Text(label(t), overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: onChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------- 第二排：撤销 / 笔记 / 提示 / 校验 / 答案 ----------
  Widget _toolbar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 4, 2, 0),
      child: Row(
        children: [
          _barButton(icon: Icons.undo, label: '撤销', onTap: _board == null ? null : _undo),
          _barButton(
            icon: Icons.edit_note,
            label: '笔记',
            active: _noteMode,
            onTap: _board == null ? null : () => setState(() => _noteMode = !_noteMode),
          ),
          _barButton(
            icon: Icons.lightbulb_outline,
            label: '提示',
            // v2.3.5：以前这里只切 `_showHint`（把空格染淡色），用户点完
            // 什么都没发生 —— 现在按一下就给一个正确数字：
            // 选中格优先，没选就随机挑一个空格。
            onTap: _board == null || _solution == null ? null : _giveHint,
          ),
          _barButton(icon: Icons.fact_check_outlined, label: '校验', onTap: _board == null ? null : _checkBoard),
          _barButton(
            icon: Icons.emoji_flags_outlined,
            label: '答案',
            onTap: _board == null ? null : _revealAnswer,
          ),
        ],
      ),
    );
  }

  // ---------- 棋盘 ----------
  Widget _boardArea() {
    final b = _board;
    final cs = Theme.of(context).colorScheme;
    if (b == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            ),
            const SizedBox(height: 12),
            Text('正在生成题目（现场计算，约 1 秒）…',
                style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
          ],
        ),
      );
    }
    // v2.3.1：所有题型现在都是方阵（不等式从 9×6 改成 6×6）
    return Padding(
      // 贴屏幕边：左右只留 2，宫格能有多大就多大（用户明确要求）
      padding: const EdgeInsets.fromLTRB(2, 2, 2, 2),
      child: Center(
        child: AspectRatio(
          aspectRatio: 1,
          child: _SudokuGrid(
            board: b,
            rules: _rules!,
            showHint: _showHint,
            solution: _solution,
            wrongCells: _checkedWrong,
            selR: _selR,
            selC: _selC,
            onCellTap: _onCellTap,
            onCellLongPress: (r, c) {
              if (b.fixed[r][c]) return;
              _pushUndo(r, c);
              _clearCell(r, c);
            },
          ),
        ),
      ),
    );
  }

  // ---------- 数字盘（常驻，不再弹底部弹窗） ----------
  Widget _pad() {
    final b = _board;
    if (b == null) return const SizedBox.shrink();
    final hasSel = _selR >= 0 && _selC >= 0;
    return _NumberPad(
      size: b.size,
      current: hasSel ? b.cells[_selR][_selC] : 0,
      notes: hasSel ? b.notes[_selR][_selC] : const <int>{},
      noteMode: _noteMode,
      remain: _remain,
      onPick: _onPick,
    );
  }

  /// 每个数字还剩几个没落（数字盘右下角的小角标）
  Map<int, int> get _remain {
    final b = _board;
    if (b == null) return const <int, int>{};
    final placed = <int, int>{};
    for (final row in b.cells) {
      for (final v in row) {
        if (v != 0) placed[v] = (placed[v] ?? 0) + 1;
      }
    }
    final per = _perNumber;
    return <int, int>{for (var v = 1; v <= b.size; v++) v: per - (placed[v] ?? 0)};
  }

  // ---------- 底部状态：用时 / 已填 / 提示语 ----------
  Widget _statusBar() {
    final cs = Theme.of(context).colorScheme;
    final b = _board;
    var filled = 0;
    if (b != null) {
      for (final row in b.cells) {
        for (final v in row) {
          if (v != 0) filled++;
        }
      }
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
      child: Row(
        children: [
          Text('用时 ${_fmtElapsed()}',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          const SizedBox(width: 14),
          Text('已填 ${b == null ? 0 : filled} / ${b == null ? 0 : b.size * b.size}',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _msg,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.primary),
            ),
          ),
        ],
      ),
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
    final fg = onTap == null
        ? cs.onSurfaceVariant.withValues(alpha: 0.4)
        : (active ? cs.onPrimaryContainer : cs.onSurfaceVariant);
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        // v2.1.0：激活时**整块**染主色（原来只染图标那一小块，
        // 「笔记」开关看不出开没开 —— 用户要求「点了变色、再点褪色」）。
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 2),
          // v2.3.0：一屏要塞下「题型 / 难度 / 五个按钮 / 棋盘 / 数字盘」，
          // 这一排压到 4 的上下留白（原来 6）。
          padding: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            color: active ? cs.primaryContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 21, color: fg),
              const SizedBox(height: 2),
              Text(label,
                  style: TextStyle(
                      fontSize: 11,
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
    setState(() {
      _checkedWrong = wrong;
      _msg = wrong.isEmpty ? '校验通过，目前没有填错的格' : '发现 ${wrong.length} 处错误，已标红';
    });
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
      setState(() => _msg = '没有可撤销的了');
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

  /// 当前选中的格子（-1 = 没选）。v2.3.0：数字盘常驻后靠它定位。
  final int selR;
  final int selC;
  final void Function(int r, int c) onCellTap;
  final void Function(int r, int c)? onCellLongPress;

  const _SudokuGrid({
    required this.board,
    required this.rules,
    required this.showHint,
    required this.solution,
    required this.onCellTap,
    this.wrongCells = const <String>{},
    this.selR = -1,
    this.selC = -1,
    this.onCellLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final n = board.size;
    final height = n; // v2.3.1：全部是方阵

    // 颜色
    final scheme = Theme.of(context).colorScheme;
    final lineColor = scheme.outlineVariant;
    final thickColor = scheme.outline;
    final bg = scheme.surface;
    final hintColor = scheme.primary.withValues(alpha: 0.18);
    final errColor = const Color(0xFFB23A3A);

    // v2.2.0 修「锯齿数独看不到锯齿」的另一半原因：
    // _cellView 里写死了「每 3 格画一条粗宫界线」（标准 3×3 宫的位置），
    // 锯齿模式下这些标准宫粗线照样在画，跟真正的锯齿宫界叠在一起，
    // 视觉上就是一张标准九宫格。锯齿时必须把标准宫线压掉，
    // 宫界全部交给 _JigsawPainter 画，同时给每个宫铺淡底色，一眼能看出锯齿。
    final isJigsaw = rules is JigsawRules;
    final regionOf = isJigsaw ? (rules as JigsawRules).regionOf : null;
    // v2.3.7（用户第 2 条：「锯齿刷新好多次才出一次正确的」）
    //
    // 老涂色是 `regionOf % 4` 取四种颜色 —— 9 个宫塞进 4 个颜色，
    // 相邻两宫撞色时整片糊在一起，玩家看到的「宫」跟真实宫界对不上，
    // 只有少数几次刷出来的编号组合恰好两两不同色，才「看着是对的」。
    // 现在按宫号给 **9 个不同色相**，任意两宫都不同色，边界一眼可辨。
    final jigsawTints = isJigsaw ? _jigsawTints(scheme) : const <Color>[];

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
                    isJigsaw: isJigsaw,
                    regionOf: regionOf,
                    jigsawTints: jigsawTints,
                  );
                },
              ),
              // 笼子 / 锯齿宫 / 不等式 / 对角线 —— 覆盖层
              if (rules is KillerRules && board.cageId != null)
                _cageOverlay(board, cell, scheme),
              if (rules is JigsawRules)
                _jigsawOverlay(rules, cell, scheme),
              if (rules is GreaterRules && board.relationMark != null)
                _greaterOverlay(board, cell, scheme),
              if (rules is EvenOddRules)
                _evenOddOverlay(rules, cell, scheme),
              // v2.3.2：对角线数独的两条对角线要**画出来**（用户说
              // 「目前看不到对角线」）。放在最上层，用半透明主色。
              if (rules is DiagonalRules) _diagonalOverlay(cell, scheme),
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
    bool isJigsaw = false,
    List<List<int>>? regionOf,
    List<Color> jigsawTints = const <Color>[],
  }) {
    final v = board.cells[r][c];
    final isFixed = board.fixed[r][c];
    final n = board.size;
    // 边框：宫界线按本题型的宫大小算（4×4 → 2×2、6×6 → 2 行 × 3 列、
    // 9×9 → 3×3）。锯齿模式例外 —— 标准宫线全部压掉，只留细网格，
    // 宫界交给锯齿绘制层。
    final boxR = rules.boxRows;
    final boxC = rules.boxCols;
    final thickTop = !isJigsaw && r > 0 && r % boxR == 0;
    final thickLeft = !isJigsaw && c > 0 && c % boxC == 0;
    final isRightThick = !isJigsaw &&
        (c == n - 1 || (((c + 1) % boxC == 0) && c != n - 1));
    final isBottomThick = !isJigsaw &&
        (r == n - 1 || (((r + 1) % boxR == 0) && r != n - 1));

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

    // v2.2.0：锯齿宫淡底色 —— 同一宫一个颜色，边界一眼能看出来。
    // v2.3.2 把透明度从 0.07 提到 0.12（用户反馈「看不出锯齿」，
    // 太淡的底色在浅色主题下几乎隐形）。
    Color cellBg = Colors.transparent;
    if (isJigsaw && regionOf != null && jigsawTints.isNotEmpty) {
      cellBg = jigsawTints[regionOf[r][c] % 9];
    }
    if (showHint && solution != null && v == 0) {
      cellBg = hintColor;
    } else if (checkedWrong) {
      cellBg = errColor.withValues(alpha: 0.18);
    }

    // v2.3.0：选中格 + 同行 / 同列 / 同宫 高亮。
    // 数字盘常驻之后，「我点的到底是不是这一格」必须一眼能看出来，
    // 否则点错了数字自己都不知道。
    final cs2 = Theme.of(context).colorScheme;
    final hasSel = selR >= 0 && selC >= 0;
    final isSel = hasSel && r == selR && c == selC;
    final isPeer = hasSel && !isSel && _isPeer(r, c, isJigsaw, regionOf);
    // v2.3.5（用户第 6 条）：选了带数字的格子后，**盘面上所有相同的数字**
    // 一起点亮。原来只亮同行 / 同列 / 同宫，玩家要数某个数字还剩几个
    // 就得一行行扫 —— 现在一眼就能看到全部位置。
    final selValue = hasSel ? board.cells[selR][selC] : 0;
    final isSameNum = hasSel && !isSel && selValue != 0 && v == selValue;
    // v2.3.7（用户第 3 条：「点击数字之后，颜色不够醒目」）
    //
    // 老配色三档都在「主色 + 低透明度」这一个色系里打转（0.22 / 0.20 / 0.07），
    // 深浅差一两个百分点，屏幕上根本分不开。
    // 现在按**三层色阶**重排，强度依次递减，一眼能分出「我点的是哪格」
    // → 「还有哪些同数字」→ 「哪些在同一行/列/宫」：
    //   选中格   = 主色**实底** + 数字反白（对比最强）
    //   相同数字 = 主色 0.34 底 + 1.6px 主色描边 + 数字加粗
    //   同行同列 = 主色 0.06 淡底（几乎只是提示）
    Color? hlBorder;
    if (isSel) {
      cellBg = cs2.primary;
      hlBorder = cs2.primary;
    } else if (isSameNum) {
      cellBg = cs2.primary.withValues(alpha: 0.34);
      hlBorder = cs2.primary.withValues(alpha: 0.85);
    } else if (isPeer && !(showHint && solution != null && v == 0) && !checkedWrong) {
      cellBg = cs2.primary.withValues(alpha: 0.06);
    }
    return GestureDetector(
      onTap: () => onCellTap(r, c),
      onLongPress: onCellLongPress == null ? null : () => onCellLongPress!(r, c),
      child: Container(
        decoration: BoxDecoration(
          color: cellBg,
          border: Border(
            // v2.3.1：宫界线按本题型的宫大小算（原来写死每 3 格的）
            top: BorderSide(
                color: thickTop ? thickColor : lineColor,
                width: thickTop ? 1.5 : 0.5),
            left: BorderSide(
                color: thickLeft ? thickColor : lineColor,
                width: thickLeft ? 1.5 : 0.5),
            right: BorderSide(
                color: isRightThick ? thickColor : lineColor, width: isRightThick ? 1.5 : 0.5),
            bottom: BorderSide(
                color: isBottomThick ? thickColor : lineColor, width: isBottomThick ? 1.5 : 0.5),
          ),
        ),
        // v2.3.7：选中格 / 相同数字额外描一圈主色（画在数字上层，压住细网格）
        foregroundDecoration: hlBorder == null
            ? null
            : BoxDecoration(
                border: Border.all(
                    color: hlBorder, width: isSel ? 2.0 : 1.6),
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
                  // 相同数字也加粗一点，底色之外再给一层视觉区分
                  fontWeight: (isSameNum || isSel) ? FontWeight.w900 : FontWeight.w600,
                  // v2.3.7：选中格是主色实底 → 数字必须反白，否则黑字糊在
                  // 深底上看不清；相同数字格用 onSurface 压住加重的底色。
                  color: (_isIllegal || checkedWrong)
                      ? (isSel ? cs2.onPrimary : errColor)
                      : isSel
                          ? cs2.onPrimary
                          : isSameNum
                              ? cs2.onSurface
                              : (isFixed ? Colors.black87 : cs2.primary),
                ),
              ),
      ),
    );
  }

  /// 9 个宫各一种色相（步长 40°，绕一圈正好盖满色环），任意两宫都不同色。
  /// v2.3.7：原来 `% 4` 只用四种颜色，9 个宫必然撞色，相邻两宫一旦同色
  /// 就糊成一整片，玩家根本看不出宫界。
  static List<Color> _jigsawTints(ColorScheme scheme) {
    final base = HSLColor.fromColor(scheme.primary);
    final dark = scheme.brightness == Brightness.dark;
    return List<Color>.generate(9, (i) {
      final hue = (base.hue + i * 40.0) % 360.0;
      return HSLColor.fromAHSL(dark ? 0.28 : 0.22, hue, 0.75, dark ? 0.60 : 0.74)
          .toColor();
    });
  }

  /// (r,c) 是不是和选中格同行 / 同列 / 同宫。
  /// 锯齿宫按真实宫界算，其它按本题型的矩形宫。
  bool _isPeer(int r, int c, bool isJigsaw, List<List<int>>? regionOf) {
    if (r == selR || c == selC) return true;
    if (isJigsaw && regionOf != null) {
      return regionOf[r][c] == regionOf[selR][selC];
    }
    return r ~/ rules.boxRows == selR ~/ rules.boxRows &&
        c ~/ rules.boxCols == selC ~/ rules.boxCols;
  }

  // ---------- 笼子（杀手） ----------
  Widget _cageOverlay(SudokuBoard b, double cell, ColorScheme scheme) {
    return SizedBox.expand(
      child: IgnorePointer(
        child: CustomPaint(
          painter: _CagePainter(
            cageId: b.cageId!,
            cages: b.cages!,
            cell: cell,
            lineColor: scheme.onSurface.withValues(alpha: 0.85),
            bgColor: scheme.surface,
          ),
        ),
      ),
    );
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

  // ---------- 对角线（对角线数独） ----------
  Widget _diagonalOverlay(double cell, ColorScheme scheme) {
    return SizedBox.expand(
      child: IgnorePointer(
        child: CustomPaint(
          painter: _DiagonalPainter(
              n: board.size,
              cell: cell,
              color: scheme.primary.withValues(alpha: 0.55)),
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

}

/// 一套内置锯齿宫布局（离线生成 + 逐套验证过）。
///
/// `regions` 是 81 个字符，按行铺开，'0'..'8' = 宫号；
/// `solution` 同样是 81 个字符，'1'..'9' = 这套布局的一个**合法解**。
class _JigsawTemplate {
  final String regions;
  final String solution;
  const _JigsawTemplate(this.regions, this.solution);
}

/// 40 套锯齿宫布局。每套都满足：
///   * 每宫恰好 9 格，且四连通（不会出现「悬空一格」）；
///   * 没有任何一个宫是规矩的 3×3 矩形（只要出现整块 3×3 同宫，那一片
///     看上去就跟普通九宫格一样，玩家会以为「这不是锯齿」）；
///   * 平均周长 ≥ 14.5（3×3 矩形是 12，越大越锯齿）；
///   * 附带已验证的合法解 —— 运行期不用再解一次，出题快、也不会翻车。
///
/// v2.3.7 重新生成：离线先造一个合法解，再反复做「边界格互换」——
/// 每次互换都保证两宫仍连通、且宫内 1..9 不重复，所以分区天然可解，
/// 不用事后搜索验证（老模板是随机长出来的，形状偏「胖」，看着仍像九宫格）。
const List<_JigsawTemplate> _kJigsawTemplates = [
  _JigsawTemplate(
      '000112222000011222001111122333335555333445455344444455666778888666677888667777788',
      '682947513497135628531862794749351286268479135153628947826794351974513862315286479'),
  _JigsawTemplate(
      '000111222030041222034441522033441552033411555633417585663477588677777888666667888',
      '265149387941837652738562419352916874487253196619784523596471238823695741174328965'),
  _JigsawTemplate(
      '000122222000111112300411552330471522633477555633477585663447885663447888666477888',
      '286937541514628739793451826937514682862379154145286973451862397628793415379145268'),
  _JigsawTemplate(
      '000011122001112222000111222334444555333444558633344558636677588666777588667777888',
      '178356249563492178492178356356249817249817635817635924781563492924781563635924781'),
  _JigsawTemplate(
      '000111222011111222000041252333044255333444555363447855663747885666777888666777888',
      '529681347437259816861734259186347592952816473743592168374925681618473925295168734'),
  _JigsawTemplate(
      '000111222000141552030141552330441522333441522363744558663747588666777888666777888',
      '914532687253768914687149325768914532325876491491253768149325876876491253532687149'),
  _JigsawTemplate(
      '001112222000011122000111222334445555333344455333444555666677778666777888667788888',
      '872356914941287653356941278728563491419872365563419827194728536635194782287635149'),
  _JigsawTemplate(
      '000111222000011222304411522306415552336415455336444455366677788367778888366777888',
      '514968327689723541237145698723514986968372415451896273145689732896237154372451869'),
  _JigsawTemplate(
      '000112222030122122030111112033444555033444555336474585636774588666788888666777778',
      '587932146461857239392641758975263481623184597814795362748529613136478925259316874'),
  _JigsawTemplate(
      '000111122030142122030142222330144555330144585333444885666778855666677885667777788',
      '758243196342691758196857342819572634634918275275436819427369581963185427581724963'),
  _JigsawTemplate(
      '000111222001111222000014552333414522344444555333334558666666588666777888777777888',
      '132965847478231695956874321695748132213659784847312569784123956569487213321596478'),
  _JigsawTemplate(
      '000114222000114222330144225300114255333714885363714885663774855666774855666777888',
      '491832756756194382382657914238576491675941238149328675914283567567419823823765149'),
  _JigsawTemplate(
      '000111222000111222030144522033114552333444555336448558636748858666777888666777778',
      '956127384271438569843569127438695271569271843712384695127843956384956712695712438'),
  _JigsawTemplate(
      '000111222000111222030114252330144552333444455336477558366475588666777888666777888',
      '179846325846532179532917846253791684917684532684253917468325791325179468791468253'),
  _JigsawTemplate(
      '000112222000014222001114422333144455331144555333345558667777588666678888666777788',
      '478139625391256784562847913846713592259684371137925468714392856685471239923568147'),
  _JigsawTemplate(
      '000111222000111222030114252330144552333444555363444585663777785666777888666778888',
      '832146579957832614146795328614579832283614957795283461579328146461957283328461795'),
  _JigsawTemplate(
      '000001122000111222011112222333444458336445558336444558366775588367775788666677788',
      '943251867867349152152768943796413285314582796285697314578936421421875639639124578'),
  _JigsawTemplate(
      '000111112000122212033112222003444555633477855633477855663447858663447858666777888',
      '942657183657381492138429675381294567429576318576813249765138924294765831813942756'),
  _JigsawTemplate(
      '000122222011111112000001222334444455344344555333335555666666888666888888777777777',
      '145379862286415973973682145628154397397826514514793286739268451451937628862541739'),
  _JigsawTemplate(
      '000111222001112222000011122333344455333444555334445585667775788666677788666778888',
      '872459316631287945594163728925634187718592463346871259289345671167928534453716892'),
  _JigsawTemplate(
      '000112222000111122030111222330445558633444458663744558633774588636777588666777588',
      '347982651165374289928156473592761348834529167716843925471238596283695714659417832'),
  _JigsawTemplate(
      '000111225300111225300144225303114255303444255333444255666778888677777788666667888',
      '271453698698217354354689712435896271869172435127534869986721543543968127712345986'),
  _JigsawTemplate(
      '001111122000011222000112252333442555333444455633477558636447858666777888666777888',
      '391874625265193874847256319526931748784562193139748256913487562652319487478625931'),
  _JigsawTemplate(
      '000011122001112222000111222333355555334444555333444445667778888666677788666777888',
      '721846935468539712953172648172684359846953127395217486217468593539721864684395271'),
  _JigsawTemplate(
      '001111122000112122000312222033344455334345555334444555667777788666778788666678888',
      '296451738514387962873629145689142573421735896357968214938216457162574389745893621'),
  _JigsawTemplate(
      '000111222000011122001112222333444555333444555633474855636478885666777888666777788',
      '831947526974652381256813479183479265497526813625138794562381947318794652749265138'),
  _JigsawTemplate(
      '000111222300111122300412222330415555330444455366474855336774858666777888666777888',
      '957324168342816597618975243186597324423681759579432816795243681234168975861759432'),
  _JigsawTemplate(
      '000011222001011222001111522333444552333444558366744558336774858666677858667777888',
      '632178549781954632549263781325681497497532816816749325163897254978425163254316978'),
  _JigsawTemplate(
      '000111122000111222003112222033444555336445558336444458366777758366778758666778888',
      '482397651561428739379516842938175426246983517157264398713652984625849173894731265'),
  _JigsawTemplate(
      '000111222000011222031114225033314255334344555334447585666647885667677888667777888',
      '691852743528734196347169825483697512976521384215348679162485937854973261739216458'),
  _JigsawTemplate(
      '000111222000111222003114252303144255333444555363447585366477588666777888666777888',
      '986245173317896254425137869259714638863529741174683592742361985598472316631958427'),
  _JigsawTemplate(
      '000111222000111122300412222330414555333444885363744885366747855666777855666777888',
      '241756893765938421983214675859423167617895342432671589394162758126587934578349216'),
  _JigsawTemplate(
      '001111222000011522300114522303144525333444525663444555633778888667778788666677788',
      '948617532253894761176325489317582946825469173694731258769153824482976315531248697'),
  _JigsawTemplate(
      '000000222000111222311114255313414225333444555363474588663477558666667888677777888',
      '536781924429635178187249635718492356653817249942356781294563817365178492871924563'),
  _JigsawTemplate(
      '000111222000141252030144252033114552333144452333445555666788888667777778666677888',
      '132964758578132469649578231496785123785321946321649875857213694964857312213496587'),
  _JigsawTemplate(
      '000111115001111225000022225333344255334344255334444255666688888666888778667777777',
      '392187456456293781781654392179846235648532179235971648524319867867425913913768524'),
  _JigsawTemplate(
      '000111222000111225330114225300144255333444255633447855636477858666777888666777888',
      '417685329932174856568932174856293417293417685741568932174856293685329741329741568'),
  _JigsawTemplate(
      '000112222000111122033441522003411525333447555366447885336477855666477888666777888',
      '546728319391564872278931645782193564465872931913456287139645728654287193827319456'),
  _JigsawTemplate(
      '000011222000111222001111522333444552334444555333364558666664858666777888777777888',
      '485912367673584921219376548892631475754298613136457289347825196961743852528169734'),
  _JigsawTemplate(
      '000022222001011222001111112333455555334444445333644555636668888666788788677777778',
      '695841723148327695723596148437652981981734256256189437519478362362915874874263519'),
];

/// 随机取一套内置锯齿宫布局，做「转置 / 上下翻 / 左右翻」+ 宫号重排 + 数字重排，
/// 返回 (宫布局, 满盘解)。
///
/// v2.3.6：**不再现场随机切宫**。之前两种切法都有硬伤 ——
///   * 「种子往外涨」：随机形状大多无解，失败就退回标准宫；
///   * 「交换相邻边界格」：在标准 3×3 宫上永远换不动（换完两边都断成
///     两截，连通性检查必然失败），交换次数恒为 0，等于原样返回标准宫。
/// 玩家看到的「只有宫格涂色、没有锯齿」就是这么来的。
(List<List<int>>, SudokuBoard) _buildJigsaw(math.Random rng) {
  final tpl = _kJigsawTemplates[rng.nextInt(_kJigsawTemplates.length)];
  final idMap = List<int>.generate(9, (i) => i)..shuffle(rng);
  final digitMap = List<int>.generate(10, (i) => i)..shuffle(rng);
  final transpose = rng.nextBool();
  final flipV = rng.nextBool();
  final flipH = rng.nextBool();
  final regions = List.generate(9, (_) => List.filled(9, 0));
  final board = SudokuBoard.empty(9);
  for (var r = 0; r < 9; r++) {
    for (var c = 0; c < 9; c++) {
      var sr = transpose ? c : r;
      var sc = transpose ? r : c;
      if (flipV) sr = 8 - sr;
      if (flipH) sc = 8 - sc;
      final i = sr * 9 + sc;
      regions[r][c] = idMap[tpl.regions.codeUnitAt(i) - 48];
      board.cells[r][c] = digitMap[tpl.solution.codeUnitAt(i) - 48];
      board.fixed[r][c] = true;
    }
  }
  return (regions, board);
}

// ============================================================ 自定义绘制

class _CagePainter extends CustomPainter {
  final List<List<int>> cageId;
  final Map<int, _Cage> cages;
  final double cell;
  final Color lineColor;
  /// 笼和数字垫底色用（穿透过去的笔记小字会把数字糊掉）
  final Color bgColor;
  _CagePainter({
    required this.cageId,
    required this.cages,
    required this.cell,
    required this.lineColor,
    required this.bgColor,
  });

  // v2.3.7（用户第 1 条：「相邻虚线框不能共用虚线，要各是各，
  // 所有虚线框的框线都独立存在，连续且不超出」）
  //
  // 老写法按**网格边**画：一条边被两个笼共用时只画一遍（`seen` 去重），
  // 于是两个笼的框在那一段**完全重合**，看着就是一根共用的线，
  // 分不清谁是谁的；而且每条边各自起虚线相位、两端各外伸 `extend`，
  // 外伸那一截在棋盘边缘、在笼子拐角都会探到框外去。
  //
  // 现在换个思路：**每个笼子只画它自己的轮廓**。
  //   1. 把笼内所有朝向笼外的边按逆时针串成一个闭环（每条边带内法线）；
  //   2. 整条闭环朝**笼内**平移 inset —— 顶点用相邻两条偏移线求交，
  //      拐角严丝合缝，也不会探出笼外；
  //   3. 沿闭环**一圈连续**画虚线：虚线相位跨顶点往下走，一圈走满正好
  //      收口（周期取 total / 整数），中途不断、结尾不多画。
  //
  // 相邻两个笼各自缩到自己那一侧，共享边处天然变成两条平行虚线、
  // 中间留 2×inset 的空，各是各的，绝不会共用。
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = lineColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      // 圆头会在闭环接缝处拱出去一点，改成平头，收口更干净
      ..strokeCap = StrokeCap.butt;

    // 缩进量：格宽 40px 时约 3px，格子再小也不低于 1.3px
    final inset = (cell * 0.075).clamp(1.3, 2.6).toDouble();

    cages.forEach((_, cage) {
      for (final loop in _outline(cage)) {
        final pts = _shrink(loop, inset);
        if (pts.length >= 3) _dashLoop(canvas, paint, pts);
      }
    });

    _paintSums(canvas, inset);
  }

  /// 把一个笼子的外边界串成闭环（格坐标，未乘 cell）。
  ///
  /// 每条边都给成「逆时针」方向，这样内法线统一是 `(-dy, dx)`：
  /// 上边界从左往右、右边界从上往下、下边界从右往左、左边界从下往上。
  List<List<Offset>> _outline(_Cage cage) {
    final segs = <List<Offset>>[];
    for (final cl in cage.cells) {
      final r = cl[0], c = cl[1];
      final id = cageId[r][c];
      bool mine(int rr, int cc) =>
          rr >= 0 && rr < cageId.length && cc >= 0 && cc < cageId.length &&
          cageId[rr][cc] == id;
      if (!mine(r - 1, c)) {
        segs.add([Offset(c.toDouble(), r.toDouble()), Offset(c + 1.0, r.toDouble())]);
      }
      if (!mine(r, c + 1)) {
        segs.add([Offset(c + 1.0, r.toDouble()), Offset(c + 1.0, r + 1.0)]);
      }
      if (!mine(r + 1, c)) {
        segs.add([Offset(c + 1.0, r + 1.0), Offset(c.toDouble(), r + 1.0)]);
      }
      if (!mine(r, c - 1)) {
        segs.add([Offset(c.toDouble(), r + 1.0), Offset(c.toDouble(), r.toDouble())]);
      }
    }

    String key(Offset p) => '${p.dx.round()},${p.dy.round()}';
    final byStart = <String, List<List<Offset>>>{};
    for (final s in segs) {
      byStart.putIfAbsent(key(s[0]), () => <List<Offset>>[]).add(s);
    }

    final used = <List<Offset>>{};
    final loops = <List<Offset>>[];
    for (final s in segs) {
      if (used.contains(s)) continue;
      final loop = <Offset>[s[0]];
      var cur = s;
      used.add(cur);
      var guard = 0;
      while (guard++ < segs.length + 2) {
        loop.add(cur[1]);
        final cands = byStart[key(cur[1])];
        List<Offset>? nxt;
        if (cands != null) {
          for (final e in cands) {
            if (!used.contains(e)) {
              nxt = e;
              break;
            }
          }
        }
        if (nxt == null) break;
        used.add(nxt);
        cur = nxt;
      }
      // 最后一点等于起点，去掉重复顶点
      if (loop.length > 1 && loop.last == loop.first) loop.removeLast();
      if (loop.length >= 3) loops.add(loop);
    }
    return loops;
  }

  /// 闭环朝笼内平移 [inset] 像素，返回像素坐标顶点。
  /// 每个顶点取「前一条偏移线」与「后一条偏移线」的交点 —— 拐角不会开口。
  List<Offset> _shrink(List<Offset> loop, double inset) {
    final k = inset / cell;
    final out = <Offset>[];
    final m = loop.length;
    for (var i = 0; i < m; i++) {
      final prev = loop[(i - 1 + m) % m];
      final cur = loop[i];
      final next = loop[(i + 1) % m];
      var d1 = cur - prev;
      var d2 = next - cur;
      if (d1.distance < 1e-6 || d2.distance < 1e-6) {
        out.add(Offset(cur.dx * cell, cur.dy * cell));
        continue;
      }
      final l1 = d1.distance, l2 = d2.distance;
      d1 = Offset(d1.dx / l1, d1.dy / l1);
      d2 = Offset(d2.dx / l2, d2.dy / l2);
      // 逆时针走行的内法线
      final n1 = Offset(-d1.dy, d1.dx);
      final n2 = Offset(-d2.dy, d2.dx);
      final a = prev + n1 * k;
      final b = cur + n2 * k;
      final den = d1.dx * d2.dy - d1.dy * d2.dx;
      Offset p;
      if (den.abs() < 1e-6) {
        // 两条边共线（直边中段），直接平移
        p = cur + n1 * k;
      } else {
        final t = ((b.dx - a.dx) * d2.dy - (b.dy - a.dy) * d2.dx) / den;
        p = a + d1 * t;
      }
      out.add(Offset(p.dx * cell, p.dy * cell));
    }
    return out;
  }

  /// 沿闭环画一整圈虚线：相位按**周长**连续推进，一圈正好整数个周期，
  /// 收口处是一个 gap，不会突然多画一截或断开。
  void _dashLoop(Canvas canvas, Paint paint, List<Offset> pts) {
    final segLen = <double>[];
    var total = 0.0;
    for (var i = 0; i < pts.length; i++) {
      final l = (pts[(i + 1) % pts.length] - pts[i]).distance;
      segLen.add(l);
      total += l;
    }
    if (total < 6) return;

    // 虚线周期取「一格的 1/5 上下」，再按周长取整 —— 每段长短一致
    final ideal = (cell / 5).clamp(4.0, 9.0).toDouble();
    final count = math.max(4, (total / ideal).round());
    final period = total / count;
    final dash = period * 0.58;

    var acc = 0.0;
    var di = 0;
    for (var i = 0; i < pts.length; i++) {
      final l = segLen[i];
      if (l <= 0) continue;
      final a = pts[i];
      final b = pts[(i + 1) % pts.length];
      final ux = (b.dx - a.dx) / l, uy = (b.dy - a.dy) / l;
      while (di < count && (di * period + dash) <= acc) {
        di++;
      }
      var kk = di;
      while (kk < count && kk * period < acc + l) {
        final s0 = math.max(kk * period, acc) - acc;
        final s1 = math.min(kk * period + dash, acc + l) - acc;
        if (s1 > s0 + 0.01) {
          canvas.drawLine(
            Offset(a.dx + ux * s0, a.dy + uy * s0),
            Offset(a.dx + ux * s1, a.dy + uy * s1),
            paint,
          );
        }
        kk++;
      }
      acc += l;
    }
  }

  /// 笼和：画在笼内「最上、再最左」那格的左上角，垫一层底色避免糊在底纹/笔记上。
  /// 位置比虚线再往里让一点，不跟框线压在一起。
  void _paintSums(Canvas canvas, double inset) {
    cages.forEach((_, cage) {
      var br = cage.cells[0][0], bc = cage.cells[0][1];
      for (final cl in cage.cells) {
        if (cl[0] < br || (cl[0] == br && cl[1] < bc)) {
          br = cl[0];
          bc = cl[1];
        }
      }
      final tp = TextPainter(
        text: TextSpan(
          text: '${cage.sum}',
          style: TextStyle(
            fontSize: cell * 0.25,
            height: 1.0,
            color: lineColor,
            fontWeight: FontWeight.w800,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final dx = bc * cell + inset + 1.8;
      final dy = br * cell + inset + 1.6;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(dx - 1.4, dy - 0.8, tp.width + 2.8, tp.height + 1.6),
          const Radius.circular(2.5),
        ),
        Paint()..color = bgColor.withValues(alpha: 0.95),
      );
      tp.paint(canvas, Offset(dx, dy));
    });
  }

  @override
  bool shouldRepaint(_CagePainter old) =>
      !identical(old.cageId, cageId) ||
      !identical(old.cages, cages) ||
      old.cell != cell ||
      old.lineColor != lineColor ||
      old.bgColor != bgColor;
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
      // v2.2.0：标准宫粗线被压掉之后，锯齿宫界就是唯一的「宫」边界，
      // 加粗让它比细网格明显一截（细网格 0.5）。v2.3.2 再提到 2.4。
      ..strokeWidth = 2.4
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
  // v2.3.5：原来恒 false —— 换题后 painter 是新实例但画布不重绘，
  // 宫界还留在上一局的形状上（连着两局锯齿时根本看不出换了题）。
  bool shouldRepaint(_JigsawPainter old) =>
      !identical(old.regionOf, regionOf) || old.cell != cell || old.lineColor != lineColor;
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
  bool shouldRepaint(_GreaterPainter old) =>
      !identical(old.marks, marks) || old.cell != cell;
}

/// 对角线数独的两条主对角线（v2.3.2 新增绘制 —— 之前只有规则没有图案，
/// 用户说「看不到对角线」）。半透明主色实线，穿过整盘两个对角。
class _DiagonalPainter extends CustomPainter {
  final int n;
  final double cell;
  final Color color;
  _DiagonalPainter({required this.n, required this.cell, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    final full = n * cell;
    // 左上 → 右下
    canvas.drawLine(const Offset(0, 0), Offset(full, full), paint);
    // 右上 → 左下
    canvas.drawLine(Offset(full, 0), Offset(0, full), paint);
  }

  @override
  bool shouldRepaint(_DiagonalPainter old) => old.cell != cell || old.n != n;
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
  bool shouldRepaint(_EvenOddPainter old) =>
      !identical(old.marks, marks) || old.cell != cell;
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
    final rows = _rows;
    final cols = rows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
    // v2.3.0：从「点格子弹出的底部弹窗」改成**常驻在棋盘下面**，
    // 所以这里不再有拖拽手柄、SafeArea 和说明文字 —— 一屏要塞得下。
    return Padding(
      padding: const EdgeInsets.fromLTRB(3, 2, 3, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  for (final v in row) Expanded(child: _pickButton(context, v)),
                  // 第二排比第一排短 → 补位占位符，保证两排按钮等宽
                  for (var k = row.length; k < cols; k++)
                    const Expanded(child: SizedBox.shrink()),
                ],
              ),
            ),
        ],
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
          // 固定 46 高：两排加起来约 100，剩下的高度全给棋盘
          height: 46,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Text(
                '$v',
                style: TextStyle(
                  fontSize: 23,
                  fontWeight: FontWeight.w600,
                  color: isCurrent ? cs.onPrimaryContainer : cs.onSurface,
                ),
              ),
              // 剩余个数角标（右下角）
              Positioned(
                right: 3,
                bottom: 1,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0.5),
                  decoration: BoxDecoration(
                    color: left <= 0
                        ? cs.primary.withValues(alpha: 0.15)
                        : cs.surface.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Text(
                    left <= 0 ? '✓' : '$left',
                    style: TextStyle(
                      fontSize: 10,
                      height: 1.15,
                      fontWeight: FontWeight.w600,
                      color: left <= 0 ? cs.primary : cs.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}