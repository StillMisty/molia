// 收编自 pub.dev 包 html_unescape 2.0.0（上游 2020 年后无活动、行为冻结，
// 迁移决策：内联收编以移除停更依赖），收编日期 2026-10-13，行为逻辑未改动。
//
// 许可：BSD-3-Clause（Copyright (c) 2018, Filip Hracek），全文如下：
//
// Copyright (c) 2018, Filip Hracek.
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//     * Neither the name of the <organization> nor the
//       names of its contributors may be used to endorse or promote products
//       derived from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL <COPYRIGHT HOLDER> BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

/// Unescapes HTML5-escaped strings.
library;

import 'src/base.dart';
import 'src/data/named_chars_all.dart' as data;

/// A [Converter] that takes HTML5-escaped strings (like `&pm;42`)
/// and unescapes them into unicode strings (like `±42`).
///
/// This class has a dictionary of more than 2000 escape sequences,
/// including virtually unused ones such as `&DoubleLongLeftRightArrow;`.
/// Consider using the smaller version from
/// `package:html_unescape/html_unescape_small.dart` if you don't need
/// the converter to be as comprehensive.
class HtmlUnescape extends HtmlUnescapeBase {
  @override
  final int maxKeyLength = data.maxKeyLength;

  @override
  final List<String> keys = data.keys;

  @override
  final List<String> values = data.values;
}
