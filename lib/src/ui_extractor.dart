part of flowmind_bridge;

/// Extracts the current UI state from Flutter's semantics tree.
class _UIExtractor {
  /// Last exception thrown by [extractState], surfaced via /debug/last_extract_error.
  static Map<String, dynamic> lastError = <String, dynamic>{};

  /// Number of nodes whose extraction was silently skipped on the most
  /// recent extractState call (because they threw inside the inner
  /// try/catch). Surfaced in the response so we can spot screens where
  /// MOST nodes are failing even though the top level didn't crash.
  static int _lastSkippedNodes = 0;

  static Future<Map<String, dynamic>> extractState() async {
    await Future.delayed(const Duration(milliseconds: 100));

    _lastSkippedNodes = 0;

    final elements = <Map<String, dynamic>>[];
    String? currentRoute;
    bool canGoBack = false;

    final semanticsOwner = WidgetsBinding.instance.pipelineOwner.semanticsOwner;
    if (semanticsOwner != null) {
      final root = semanticsOwner.rootSemanticsNode;
      if (root != null) {
        _extractNode(root, elements);
      }
    }

    final navigator = FlowMindBridge.navigatorKey?.currentState;
    if (navigator != null) {
      canGoBack = navigator.canPop();
      currentRoute = _getCurrentRoute(navigator);
    }

    final screenId = _generateScreenId(currentRoute, elements);

    // Post-process dedup: collapse entries with identical (label, type),
    // keeping the LAST one — which is the deepest in tree-traversal order
    // and therefore the actual editable/clickable widget rather than its
    // labeled wrapper. This handles Material's nested Semantics layering
    // (TextField wrapped in FormField wrapped in custom input widget)
    // without entangling with MergeSemantics edge cases.
    final dedupedElements = _dedupByLabelAndType(elements);

    // Sanitize all string values before returning
    final response = <String, dynamic>{
      'screen_id': _sanitizeString(screenId),
      'route': currentRoute != null ? _sanitizeString(currentRoute) : null,
      'elements': dedupedElements.map(_sanitizeElement).toList(),
      'navigation': {'can_go_back': canGoBack},
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };
    if (_lastSkippedNodes > 0) {
      // Tell whoever's asking that some nodes were skipped — useful when
      // the response looks suspiciously sparse. Skipped nodes are also
      // logged to the flutter console as they happen.
      response['skipped_nodes'] = _lastSkippedNodes;
    }
    return response;
  }

  /// Collapse elements with the same (label, type) into a single entry,
  /// preserving original tree-traversal order for entries that survive.
  static List<Map<String, dynamic>> _dedupByLabelAndType(
      List<Map<String, dynamic>> elements) {
    // Walk in order, keep an index-of-last-occurrence per key, then emit
    // each entry only at its last index — preserves overall ordering.
    final lastIndexByKey = <String, int>{};
    for (var i = 0; i < elements.length; i++) {
      final e = elements[i];
      final key = '${e['label']}|${e['type']}';
      lastIndexByKey[key] = i;
    }
    final keepIndices = lastIndexByKey.values.toSet();
    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < elements.length; i++) {
      if (keepIndices.contains(i)) out.add(elements[i]);
    }
    return out;
  }

  /// Remove non-ASCII / problematic characters from a string for safe JSON transport
  static String _sanitizeString(String input) {
    // Replace Romanian and other diacritics with ASCII equivalents
    final roMap = {
      'ă': 'a',
      'â': 'a',
      'î': 'i',
      'ș': 's',
      'ț': 't',
      'Ă': 'A',
      'Â': 'A',
      'Î': 'I',
      'Ș': 'S',
      'Ț': 'T',
      'ö': 'o',
      'ü': 'u',
      'ä': 'a',
      'ß': 'ss',
      'é': 'e',
      'è': 'e',
      'ê': 'e',
      'ë': 'e',
      'à': 'a',
      'á': 'a',
      'ã': 'a',
      'ì': 'i',
      'í': 'i',
      'ï': 'i',
      'ò': 'o',
      'ó': 'o',
      'õ': 'o',
      'ô': 'o',
      'ù': 'u',
      'ú': 'u',
      'û': 'u',
      'ç': 'c',
      'ñ': 'n',
    };

    String result = input;
    roMap.forEach((from, to) {
      result = result.replaceAll(from, to);
    });

    // Remove any remaining non-ASCII characters
    result = result.replaceAll(RegExp(r'[^\x00-\x7F]'), '');

    // Trim to reasonable length
    if (result.length > 80) result = result.substring(0, 80);

    return result;
  }

  /// Sanitize label/hint/value for display (keep diacritics, just limit length).
  ///
  /// Bug history: the previous version computed the cap from `input.length`
  /// but called `substring` on the result of `replaceAll(...).trim()`, which
  /// can be SHORTER than the original. For inputs longer than 200 chars
  /// where the cleaned form is e.g. 195 chars, `substring(0, 200)` threw
  /// `RangeError`. One thrown label crashed the whole screen extract because
  /// `extractState`'s `.map(_sanitizeElement).toList()` propagates the
  /// first failure — turning every long-text screen (survey questions,
  /// long descriptions) into `transitioning_screen` for the bridge.
  static String _sanitizeLabel(String input) {
    final cleaned = input
        .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), '')
        .trim();
    return cleaned.length > 200 ? cleaned.substring(0, 200) : cleaned;
  }

  static Map<String, dynamic> _sanitizeElement(Map<String, dynamic> elem) {
    return {
      'id': _sanitizeString(elem['id']?.toString() ?? ''),
      'type': elem['type'] ?? 'widget',
      'label': _sanitizeLabel(elem['label']?.toString() ?? ''),
      'value': elem['value'] != null
          ? _sanitizeLabel(elem['value'].toString())
          : null,
      'hint':
          elem['hint'] != null ? _sanitizeLabel(elem['hint'].toString()) : null,
      'enabled': elem['enabled'] ?? true,
      'visible': elem['visible'] ?? true,
      'rect': elem['rect'],
    };
  }

  static void _extractNode(
      SemanticsNode node, List<Map<String, dynamic>> elements) {
    try {
      if (!node.isInvisible && !node.isMergedIntoParent) {
        final data = node.getSemanticsData();
        final label = data.label.isNotEmpty
            ? data.label
            : data.hint.isNotEmpty
                ? data.hint
                : data.value.isNotEmpty
                    ? data.value
                    : '';

        if (label.isNotEmpty) {
          try {
            // Always emit. Dedup of nested wrappers happens later in
            // _dedupByLabelAndType so the logic stays out of the recursive
            // walk and doesn't entangle with Material's MergeSemantics
            // (which would otherwise drop fields whose inner editable is
            // marked isMergedIntoParent).
            final rect = node.rect;
            final id = _makeId(label, node.id);
            final type = _inferType(data);

            elements.add({
              'id': id,
              'type': type,
              'label': _sanitizeLabel(label),
              'value': data.value.isEmpty ? null : _sanitizeLabel(data.value),
              'hint': data.hint.isEmpty ? null : _sanitizeLabel(data.hint),
              'enabled': !data.hasFlag(SemanticsFlag.isReadOnly),
              'visible': true,
              'rect': {
                'x': rect.left,
                'y': rect.top,
                'width': rect.width,
                'height': rect.height,
              },
            });
          } catch (e, st) {
            // Don't crash the whole walk on one bad element, but stop
            // pretending it didn't happen — count + log so we can
            // diagnose screens where most elements get silently dropped.
            _lastSkippedNodes++;
            FlowMindBridge._log('[extract] skipped node id=${node.id} label="${data.label}" reason: $e');
            FlowMindBridge._log('[extract] stack: $st');
          }
        }
      }
    } catch (e, st) {
      _lastSkippedNodes++;
      FlowMindBridge._log('[extract] outer catch on node id=${node.id} reason: $e');
      FlowMindBridge._log('[extract] stack: $st');
    }

    node.visitChildren((child) {
      try {
        _extractNode(child, elements);
      } catch (e, st) {
        _lastSkippedNodes++;
        FlowMindBridge._log('[extract] visitChildren swallowed: $e');
        FlowMindBridge._log('[extract] stack: $st');
      }
      return true;
    });
  }


  static String _inferType(SemanticsData data) {
    if (data.hasFlag(SemanticsFlag.isTextField)) return 'text_field';
    if (data.hasFlag(SemanticsFlag.isButton)) return 'button';
    if (data.hasFlag(SemanticsFlag.isChecked) ||
        data.hasFlag(SemanticsFlag.hasCheckedState)) return 'checkbox';
    if (data.hasFlag(SemanticsFlag.isToggled) ||
        data.hasFlag(SemanticsFlag.hasToggledState)) return 'switch';
    if (data.hasAction(SemanticsAction.tap)) return 'tappable';
    if (data.hasFlag(SemanticsFlag.isLink)) return 'link';
    if (data.hasFlag(SemanticsFlag.isHeader)) return 'header';
    if (data.hasFlag(SemanticsFlag.isImage)) return 'image';
    return 'widget';
  }

  static String _makeId(String label, int nodeId) {
    // Sanitize first (removes diacritics), then slugify
    final sanitized = _sanitizeString(label);
    final slug = sanitized
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    final idPart = slug.isEmpty ? 'element' : slug;
    final suffix = '_$nodeId';
    final maxLen = 40;
    final maxSlug = (maxLen - suffix.length).clamp(1, maxLen);
    final trimmed =
        idPart.length > maxSlug ? idPart.substring(0, maxSlug) : idPart;
    return '$trimmed$suffix';
  }

  static String? _getCurrentRoute(NavigatorState navigator) {
    String? route;
    navigator.popUntil((r) {
      route = r.settings.name;
      return true;
    });
    return route;
  }

  static String _generateScreenId(
      String? route, List<Map<String, dynamic>> elements) {
    // Try route first. Lowercase BEFORE the [^a-z0-9_] strip — otherwise
    // every uppercase letter gets stripped (e.g. "StartedSurveysListScreen"
    // → "tartedurveysistcreen") because the strip regex was anchored to
    // lowercase only.
    if (route != null && route.isNotEmpty) {
      final sanitized = _sanitizeString(route.replaceAll('/', '_'));
      final clean = sanitized
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9_]'), '')
          .replaceAll(RegExp(r'^_+|_+$'), '');
      if (clean.isNotEmpty) return clean;
    }
    // Try first element label
    if (elements.isNotEmpty) {
      final label = elements.first['label'] as String? ?? '';
      final sanitized = _sanitizeString(label);
      final clean = sanitized
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9]'), '_')
          .replaceAll(RegExp(r'_+'), '_')
          .replaceAll(RegExp(r'^_+|_+$'), '');
      if (clean.isNotEmpty)
        return clean.length > 30 ? clean.substring(0, 30) : clean;
    }
    // Fallback to element count hash
    return 'screen_${elements.length}';
  }
}
