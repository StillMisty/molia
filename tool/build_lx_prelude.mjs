#!/usr/bin/env node
// 构建打包用的 LX 前导脚本（terser 压缩）。
//
// 源码：tool/lx_prelude/lx_prelude.js（可读、带注释，唯一修改入口）
// 产物：assets/lx/lx_prelude.js（APK 实际打包的文件，勿手改）
//
// 用法：
//   node tool/build_lx_prelude.mjs          # 重新生成产物
//   node tool/build_lx_prelude.mjs --check  # 只校验产物是否与源码同步（提交前/CI）
//
// 压缩安全前提：terser 默认 --mangle 只重命名函数作用域局部变量，
// 顶层全局名（脚本依赖的 lx / __lxMd5 等宿主注入名字）保持不变。

import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const SRC = path.join(ROOT, 'tool/lx_prelude/lx_prelude.js');
const OUT = path.join(ROOT, 'assets/lx/lx_prelude.js');
// 固定 terser 版本：保证 --check 输出可复现。
const TERSER = 'terser@5.51.2';
const BANNER =
  '/*! molia lx_prelude.js（terser 压缩产物；源码：tool/lx_prelude/lx_prelude.js，' +
  '修改后运行 node tool/build_lx_prelude.mjs 重新生成） */\n';

function minify() {
  const tmp = mkdtempSync(path.join(tmpdir(), 'lx-prelude-'));
  try {
    const out = path.join(tmp, 'out.js');
    execFileSync(
      'npx',
      ['--yes', TERSER, SRC, '--compress', '--mangle', '--comments', 'false', '-o', out],
      { stdio: ['ignore', 'ignore', 'inherit'] },
    );
    return BANNER + readFileSync(out, 'utf8');
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
}

const checkOnly = process.argv.includes('--check');
const next = minify();

let current = '';
try {
  current = readFileSync(OUT, 'utf8');
} catch {
  // 产物缺失按不同步处理。
}

if (checkOnly) {
  if (current !== next) {
    console.error(
        '✗ assets/lx/lx_prelude.js 与源码不同步：请运行 node tool/build_lx_prelude.mjs');
    process.exit(1);
  }
  console.log('✓ lx_prelude 产物与源码同步');
} else if (current === next) {
  console.log('✓ 产物已是最新，无需重写');
} else {
  writeFileSync(OUT, next);
  console.log(`✓ 已生成 ${path.relative(ROOT, OUT)}（${Buffer.byteLength(next)} B）`);
}
