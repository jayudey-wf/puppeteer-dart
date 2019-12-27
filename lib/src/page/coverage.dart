import 'dart:async';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import '../../protocol/css.dart';
import '../../protocol/debugger.dart';
import '../../protocol/dev_tools.dart';
import '../../protocol/profiler.dart';
import '../../protocol/runtime.dart';
import 'execution_context.dart';

final _logger = Logger('puppeteer.coverage');

class CoverageEntry {
  final String url, text;
  final List<Range> ranges;

  CoverageEntry(
      {@required this.url, @required this.text, @required this.ranges})
      : assert(url != null),
        assert(text != null),
        assert(ranges != null);

  Map<String, dynamic> toJson() => {
        'url': url,
        'ranges': ranges,
        'text': text,
      };

  @override
  String toString() => 'CoverageEntry(url: $url, ranges: $ranges, text: $text)';
}

class Range {
  final int _start;
  int _end;

  Range(this._start, this._end)
      : assert(_start != null),
        assert(_end != null);

  int get start => _start;

  int get end => _end;

  Map<String, dynamic> toJson() => {'start': start, 'end': end};

  @override
  bool operator ==(other) =>
      other is Range && other.start == start && other.end == end;

  @override
  int get hashCode => start.hashCode + end.hashCode;

  @override
  String toString() => 'Range(start: $start, end: $end)';
}

/// Coverage gathers information about parts of JavaScript and CSS that were used by the page.
///
/// An example of using JavaScript and CSS coverage to get percentage of initially
/// executed code:
///
/// ```dart
/// // Enable both JavaScript and CSS coverage
/// await Future.wait(
///     [page.coverage.startJSCoverage(), page.coverage.startCSSCoverage()]);
/// // Navigate to page
/// await page.goto('https://example.com');
/// // Disable both JavaScript and CSS coverage
/// var jsCoverage = await page.coverage.stopJSCoverage();
/// var cssCoverage = await page.coverage.stopCSSCoverage();
/// var totalBytes = 0;
/// var usedBytes = 0;
/// var coverage = [...jsCoverage, ...cssCoverage];
/// for (var entry in coverage) {
///   totalBytes += entry.text.length;
///   for (var range in entry.ranges) {
///     usedBytes += range.end - range.start - 1;
///   }
/// }
/// print('Bytes used: ${usedBytes / totalBytes * 100}%');
/// ```
class Coverage {
  final JsCoverage _jsCoverage;
  final CssCoverage _cssCoverage;

  Coverage(DevTools devTools)
      : _jsCoverage = JsCoverage(devTools),
        _cssCoverage = CssCoverage(devTools);

  /// Parameters:
  ///   - `resetOnNavigation` Whether to reset coverage on every navigation.
  ///     Defaults to `true`.
  ///   - `reportAnonymousScripts`: Whether anonymous scripts generated by the
  ///     page should be reported. Defaults to `false`.
  ///
  /// Returns a Future that resolves when coverage is started
  ///
  /// > **NOTE** Anonymous scripts are ones that don't have an associated url.
  /// These are scripts that are dynamically created on the page using `eval` or
  /// `new Function`. If `reportAnonymousScripts` is set to `true`, anonymous
  /// scripts will have `__puppeteer_evaluation_script__` as their URL.
  Future<void> startJSCoverage(
      {bool resetOnNavigation, bool reportAnonymousScripts}) {
    return _jsCoverage.start(
        resetOnNavigation: resetOnNavigation,
        reportAnonymousScripts: reportAnonymousScripts);
  }

  /// Returns a Future that resolves to the array of coverage reports for all scripts
  ///   - `url`: Script URL
  ///   - `text`: Script content
  ///   - `ranges`: Script ranges that were executed. Ranges are sorted and non-overlapping.
  ///     - `start`: A start offset in text, inclusive
  ///     - `end`: An end offset in text, exclusive
  ///
  /// > **NOTE** JavaScript Coverage doesn't include anonymous scripts by default.
  ///  However, scripts with sourceURLs are reported.
  Future<List<CoverageEntry>> stopJSCoverage() {
    return _jsCoverage.stop();
  }

  /// Parameters
  ///  - `resetOnNavigation`:  Whether to reset coverage on every navigation.
  ///    Defaults to `true`.
  ///
  ///  Returns: Future that resolves when coverage is started
  Future<void> startCSSCoverage({bool resetOnNavigation}) {
    return _cssCoverage.start(resetOnNavigation: resetOnNavigation);
  }

  /// Returns a Future that resolves to the array of coverage reports for all
  /// stylesheets
  //  - `url`: StyleSheet URL
  //  - `text`: StyleSheet content
  //  - `ranges`: StyleSheet ranges that were used. Ranges are sorted and non-overlapping.
  //    - `start`: A start offset in text, inclusive
  //    - `end`: An end offset in text, exclusive
  //
  //> **NOTE** CSS Coverage doesn't include dynamically injected style tags
  // without sourceURLs.
  Future<List<CoverageEntry>> stopCSSCoverage() {
    return _cssCoverage.stop();
  }
}

class JsCoverage {
  final DevTools _devTools;
  final _scriptUrls = <ScriptId, String>{};
  final _scriptSources = <ScriptId, String>{};
  List<StreamSubscription> _subscriptions;
  bool _enabled = false;
  bool _resetOnNavigation = false;
  bool _reportAnonymousScripts = false;

  JsCoverage(this._devTools);

  Future<void> start(
      {bool resetOnNavigation, bool reportAnonymousScripts}) async {
    assert(!_enabled, 'JSCoverage is already enabled');

    resetOnNavigation ??= true;
    reportAnonymousScripts ??= false;

    _resetOnNavigation = resetOnNavigation;
    _reportAnonymousScripts = reportAnonymousScripts;
    _enabled = true;
    _scriptUrls.clear();
    _scriptSources.clear();
    _subscriptions = [
      _devTools.debugger.onScriptParsed.listen(_onScriptParsed),
      _devTools.runtime.onExecutionContextsCleared
          .listen(_onExecutionContextsCleared),
    ];
    await Future.wait([
      _devTools.profiler.enable(),
      _devTools.profiler.startPreciseCoverage(callCount: false, detailed: true),
      _devTools.debugger.enable(),
      _devTools.debugger.setSkipAllPauses(true),
    ]);
  }

  void _onExecutionContextsCleared(_) {
    if (!_resetOnNavigation) return;
    _scriptUrls.clear();
    _scriptSources.clear();
  }

  Future<void> _onScriptParsed(ScriptParsedEvent event) async {
    // Ignore puppeteer-injected scripts
    if (event.url == evaluationScriptUrl) return;
    // Ignore other anonymous scripts unless the reportAnonymousScripts option is true.
    if (_isNullOrEmpty(event.url) && !_reportAnonymousScripts) return;
    try {
      var response = await _devTools.debugger.getScriptSource(event.scriptId);
      _scriptUrls[event.scriptId] = event.url;
      _scriptSources[event.scriptId] = response;
    } catch (e) {
      // This might happen if the page has already navigated away.
      _logger.fine('_onScriptParsed error', e);
    }
  }

  Future<List<CoverageEntry>> stop() async {
    assert(_enabled, 'JSCoverage is not enabled');
    _enabled = false;
    var profileResponseFuture = _devTools.profiler.takePreciseCoverage();

    await Future.wait([
      profileResponseFuture,
      _devTools.profiler.stopPreciseCoverage(),
      _devTools.profiler.disable(),
      _devTools.debugger.disable(),
    ]);

    var profileResponse = await profileResponseFuture;

    for (var s in _subscriptions) {
      await s.cancel();
    }

    var coverage = <CoverageEntry>[];
    for (var entry in profileResponse) {
      var url = _scriptUrls[entry.scriptId];
      if (_isNullOrEmpty(url) && _reportAnonymousScripts) {
        url = 'debugger://VM${entry.scriptId}';
      }
      var text = _scriptSources[entry.scriptId];
      if (text == null || _isNullOrEmpty(url)) continue;
      var flattenRanges = <CoverageRange>[];
      for (var func in entry.functions) {
        flattenRanges.addAll(func.ranges);
      }
      var ranges = _convertToDisjointRanges(flattenRanges);
      coverage.add(CoverageEntry(url: url, text: text, ranges: ranges));
    }
    return coverage;
  }
}

bool _isNullOrEmpty(String input) => input == null || input.isEmpty;

class CssCoverage {
  final DevTools _devTools;
  final _stylesheetUrls = <StyleSheetId, String>{};
  final _stylesheetSources = <StyleSheetId, String>{};
  List<StreamSubscription> _subscriptions;
  bool _enabled = false;
  bool _resetOnNavigation = false;

  CssCoverage(this._devTools);

  Future<void> start({bool resetOnNavigation}) async {
    assert(!_enabled, 'CSSCoverage is already enabled');
    resetOnNavigation ??= true;

    _resetOnNavigation = resetOnNavigation;
    _enabled = true;
    _stylesheetUrls.clear();
    _stylesheetSources.clear();
    _subscriptions = [
      _devTools.css.onStyleSheetAdded.listen(_onStyleSheet),
      _devTools.runtime.onExecutionContextsCleared
          .listen(_onExecutionContextsCleared),
    ];
    await Future.wait([
      _devTools.dom.enable(),
      _devTools.css.enable(),
      _devTools.css.startRuleUsageTracking(),
    ]);
  }

  void _onExecutionContextsCleared(_) {
    if (!_resetOnNavigation) return;
    _stylesheetUrls.clear();
    _stylesheetSources.clear();
  }

  Future<void> _onStyleSheet(CSSStyleSheetHeader header) async {
    // Ignore anonymous scripts
    if (_isNullOrEmpty(header.sourceURL)) return;
    try {
      var response = await _devTools.css.getStyleSheetText(header.styleSheetId);
      _stylesheetUrls[header.styleSheetId] = header.sourceURL;
      _stylesheetSources[header.styleSheetId] = response;
    } catch (e) {
      // This might happen if the page has already navigated away.
      _logger.fine('Error in _onStyleSheet', e);
    }
  }

  Future<List<CoverageEntry>> stop() async {
    assert(_enabled, 'CSSCoverage is not enabled');
    _enabled = false;
    var ruleTrackingResponse = await _devTools.css.stopRuleUsageTracking();
    await Future.wait([
      _devTools.css.disable(),
      _devTools.dom.disable(),
    ]);
    _subscriptions.forEach((s) => s.cancel());

    // aggregate by styleSheetId
    var styleSheetIdToCoverage = <StyleSheetId, List<CoverageRange>>{};
    for (var entry in ruleTrackingResponse) {
      var ranges = styleSheetIdToCoverage[entry.styleSheetId];
      if (ranges == null) {
        ranges = <CoverageRange>[];
        styleSheetIdToCoverage[entry.styleSheetId] = ranges;
      }
      ranges.add(CoverageRange(
          startOffset: entry.startOffset.toInt(),
          endOffset: entry.endOffset.toInt(),
          count: entry.used ? 1 : 0));
    }

    var coverage = <CoverageEntry>[];
    for (var styleSheetId in _stylesheetUrls.keys) {
      var url = _stylesheetUrls[styleSheetId];
      var text = _stylesheetSources[styleSheetId];
      var ranges =
          _convertToDisjointRanges(styleSheetIdToCoverage[styleSheetId] ?? []);
      coverage.add(CoverageEntry(url: url, text: text, ranges: ranges));
    }

    return coverage;
  }
}

class _Point {
  final int offset, type;
  final CoverageRange range;

  _Point({@required this.offset, @required this.type, @required this.range});
}

List<Range> _convertToDisjointRanges(List<CoverageRange> nestedRanges) {
  var points = <_Point>[];
  for (var range in nestedRanges) {
    points.add(_Point(offset: range.startOffset, type: 0, range: range));
    points.add(_Point(offset: range.endOffset, type: 1, range: range));
  }
  // Sort points to form a valid parenthesis sequence.
  points.sort((a, b) {
    // Sort with increasing offsets.
    if (a.offset != b.offset) return a.offset - b.offset;
    // All "end" points should go before "start" points.
    if (a.type != b.type) return b.type - a.type;
    var aLength = a.range.endOffset - a.range.startOffset;
    var bLength = b.range.endOffset - b.range.startOffset;
    // For two "start" points, the one with longer range goes first.
    if (a.type == 0) return bLength - aLength;
    // For two "end" points, the one with shorter range goes first.
    return aLength - bLength;
  });

  var hitCountStack = <int>[];
  var results = <Range>[];
  var lastOffset = 0;
  // Run scanning line to intersect all ranges.
  for (var point in points) {
    if (hitCountStack.isNotEmpty &&
        lastOffset < point.offset &&
        hitCountStack[hitCountStack.length - 1] > 0) {
      var lastResult = results.isNotEmpty ? results[results.length - 1] : null;
      if (lastResult != null && lastResult.end == lastOffset) {
        lastResult._end = point.offset;
      } else {
        results.add(Range(lastOffset, point.offset));
      }
    }
    lastOffset = point.offset;
    if (point.type == 0) {
      hitCountStack.add(point.range.count);
    } else {
      hitCountStack.removeLast();
    }
  }
  // Filter out empty ranges.
  return results.where((range) => range.end - range.start > 1).toList();
}