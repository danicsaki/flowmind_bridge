part of flowmind_bridge;

/// Executes actions on the Flutter app via the semantics system.
class _ActionExecutor {
  static Future<Map<String, dynamic>> execute(
      String path, Map<String, dynamic> body) async {
    try {
      switch (path) {
        case '/action/tap':
          return await _tap(body);
        case '/action/type':
          return await _type(body);
        case '/action/scroll':
          return await _scroll(body);
        case '/action/back':
          return await _back();
        case '/action/long_press':
          return await _longPress(body);
        default:
          return {'success': false, 'error': 'Unknown action: $path'};
      }
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Tap
  // ─────────────────────────────────────────────────────────────────────────

  /// Records the most recent tap dispatch — exposed via /debug/last_tap so
  /// you can introspect what the bridge actually did without re-running.
  static Map<String, dynamic> lastTap = <String, dynamic>{};

  static Future<Map<String, dynamic>> _tap(Map<String, dynamic> body) async {
    final elementId = body['element_id'] as String?;
    final label = body['label'] as String?;

    FlowMindBridge._log('[tap] received element_id=$elementId label=$label');

    // First lookup. If the semantics tree happens to be mid-rebuild (common
    // right after a chain like Trimite răspuns → button relabel), the node
    // we're after may briefly disappear. Retry once after a 200ms pause so
    // a single transient miss doesn't make the executor abandon a working
    // path. Both attempts log their result for /debug/last_tap traceability.
    SemanticsNode? node = _findNode(elementId: elementId, label: label);
    if (node == null) {
      FlowMindBridge._log('[tap] miss on first attempt — retrying in 200ms');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      node = _findNode(elementId: elementId, label: label);
    }
    if (node == null) {
      FlowMindBridge._log('[tap] no matching node after retry — bailing');
      lastTap = {
        'requested_id': elementId,
        'requested_label': label,
        'matched': false,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };
      return {'success': false, 'error': 'Element not found: $elementId / $label'};
    }

    final data = node.getSemanticsData();
    final hasTapAction = data.hasAction(SemanticsAction.tap);
    FlowMindBridge._log(
      '[tap] matched node id=${node.id} label="${data.label}" '
      'rect=${node.rect} hasTapAction=$hasTapAction',
    );

    // Choose ONE dispatch path based on capability. Firing both used to
    // make sense as a workaround for widgets without SemanticsAction.tap,
    // but for properly-instrumented widgets (Semantics(onTap: ...)) it
    // invokes the user's callback twice — the first fires navigation,
    // the second lands on the in-flight transition and pops it back.
    // Net visible effect: nothing changed.
    String method;
    Offset? centre;
    bool pointerOk = false;

    if (hasTapAction) {
      _triggerSemanticsAction(node, SemanticsAction.tap);
      FlowMindBridge._log('[tap] dispatched SemanticsAction.tap to node ${node.id}');
      method = 'semantics';
    } else {
      // No semantic tap action registered — fall back to a synthetic
      // pointer event at the widget's centre. Catches BottomNavigationBar
      // items, custom GestureDetectors, AlertDialog buttons that haven't
      // been wrapped in Semantics(onTap:).
      centre = _semanticsNodeGlobalCenter(node);
      pointerOk = await _dispatchPointerTap(node);
      FlowMindBridge._log(
        '[tap] no SemanticsAction.tap — pointer dispatched=$pointerOk centre=$centre',
      );
      method = pointerOk ? 'pointer' : 'none';
    }

    await _settle();

    lastTap = {
      'requested_id': elementId,
      'requested_label': label,
      'matched': true,
      'matched_node_id': node.id,
      'matched_label': data.label,
      'rect_local': {
        'x': node.rect.left, 'y': node.rect.top,
        'w': node.rect.width, 'h': node.rect.height,
      },
      'pointer_centre': centre == null ? null : {'x': centre.dx, 'y': centre.dy},
      'has_tap_action': hasTapAction,
      'semantics_dispatched': hasTapAction,
      'pointer_dispatched': pointerOk,
      'method': method,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };

    return {
      'success': method != 'none',
      'method': method,
    };
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Type text
  // ─────────────────────────────────────────────────────────────────────────
  static Future<Map<String, dynamic>> _type(Map<String, dynamic> body) async {
    final elementId = body['element_id'] as String?;
    final label = body['label'] as String?;
    final text = body['text'] as String? ?? '';

    FlowMindBridge._log(
      '[type] received element_id=$elementId label=$label '
      'text_len=${text.length} registry_keys=${FlowMindFieldRegistry.registeredKeys()}',
    );

    // Path 1: direct controller registry (preferred). Skips Material's
    // duplicate-Semantics layering entirely — the host widget handed us
    // its TextEditingController, so we just write to it.
    final controller =
        FlowMindFieldRegistry.lookup(label) ?? FlowMindFieldRegistry.lookup(elementId);
    if (controller != null) {
      controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      FlowMindBridge._log('[type] registry hit — wrote ${text.length} chars');
      await _settle();
      return {'success': true, 'method': 'registry'};
    }

    FlowMindBridge._log('[type] registry miss — falling back to semantics search');

    // Path 2: semantics fallback for fields that haven't opted into the
    // registry. _searchNode now recurses-first and requires setText
    // capability, so it picks the inner editable rather than the wrapper.
    SemanticsNode? node = _findNode(elementId: elementId, label: label, isTextField: true);
    if (node == null) {
      // Same retry pattern as _tap — semantics tree may be mid-rebuild.
      FlowMindBridge._log('[type] semantics miss — retrying in 200ms');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      node = _findNode(elementId: elementId, label: label, isTextField: true);
    }
    if (node == null) {
      FlowMindBridge._log('[type] no setText-capable node found — bailing');
      return {'success': false, 'error': 'TextField not found: $elementId / $label'};
    }

    // Focus first — required so the framework binds the keyboard / IME state
    // to this field before we push text into it.
    _triggerSemanticsAction(node, SemanticsAction.tap);
    await Future.delayed(const Duration(milliseconds: 50));

    _triggerSemanticsAction(node, SemanticsAction.setText, argument: text);
    FlowMindBridge._log('[type] semantics dispatched setText to node ${node.id}');
    await _settle();
    return {'success': true, 'method': 'semantics'};
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Scroll
  // ─────────────────────────────────────────────────────────────────────────
  static Future<Map<String, dynamic>> _scroll(Map<String, dynamic> body) async {
    final direction = body['direction'] as String? ?? 'down';

    final action = direction == 'down'
        ? SemanticsAction.scrollDown
        : direction == 'up'
            ? SemanticsAction.scrollUp
            : direction == 'left'
                ? SemanticsAction.scrollLeft
                : SemanticsAction.scrollRight;

    // Find first scrollable
    final node = _findScrollable();
    if (node != null) {
      _triggerSemanticsAction(node, action);
    }

    await _settle();
    return {'success': true};
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Navigate back
  // ─────────────────────────────────────────────────────────────────────────
  static Future<Map<String, dynamic>> _back() async {
    final navigator = FlowMindBridge.navigatorKey?.currentState;
    if (navigator != null && navigator.canPop()) {
      navigator.pop();
      await _settle();
      return {'success': true};
    }
    return {'success': false, 'error': 'Cannot go back — already at root'};
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Long press
  // ─────────────────────────────────────────────────────────────────────────
  static Future<Map<String, dynamic>> _longPress(Map<String, dynamic> body) async {
    final elementId = body['element_id'] as String?;
    final node = _findNode(elementId: elementId);
    if (node == null) {
      return {'success': false, 'error': 'Element not found: $elementId'};
    }
    _triggerSemanticsAction(node, SemanticsAction.longPress);
    await _settle();
    return {'success': true};
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Helpers
  // ─────────────────────────────────────────────────────────────────────────

  static void _triggerSemanticsAction(
      SemanticsNode node, SemanticsAction action,
      {Object? argument}) {
    WidgetsBinding.instance.pipelineOwner.semanticsOwner?.performAction(
      node.id,
      action,
      argument,
    );
  }

  /// Monotonic pointer ID — every synthetic touch needs a unique device
  /// ID or Flutter's gesture arena gets confused on consecutive taps.
  static int _pointerCounter = 1000;

  /// Dispatch a synthetic touch (down → up) at the centre of [node]'s
  /// rect, in global coordinates. Returns false if we couldn't compute a
  /// meaningful position (rect empty, node detached, transform missing).
  static Future<bool> _dispatchPointerTap(SemanticsNode node) async {
    try {
      final centre = _semanticsNodeGlobalCenter(node);
      if (centre == null) return false;

      final pointer = ++_pointerCounter;
      final binding = GestureBinding.instance;
      final downAt = Duration.zero;
      final upAt = const Duration(milliseconds: 50);

      binding.handlePointerEvent(PointerDownEvent(
        pointer: pointer,
        position: centre,
        timeStamp: downAt,
      ));
      // A short gap so the gesture arena resolves a tap (not a long-press).
      await Future<void>.delayed(const Duration(milliseconds: 30));
      binding.handlePointerEvent(PointerUpEvent(
        pointer: pointer,
        position: centre,
        timeStamp: upAt,
      ));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Walk up the parent chain composing per-node transforms so we can
  /// resolve the node's centre in root (global) coordinates, then divide
  /// by device pixel ratio.
  ///
  /// Two things to know:
  ///  - SemanticsNode.transform maps THIS node's coords into its parent's
  ///    coord system, so applying transforms top-down (root → leaf) and
  ///    then mapping the local centre yields a point in root semantics
  ///    coords.
  ///  - The root semantics transform includes device-pixel-ratio scaling,
  ///    which leaves the result in **physical** pixels. `handlePointerEvent`
  ///    expects **logical** pixels (the framework converts platform pointer
  ///    data from physical to logical before this entry point), so we
  ///    divide by DPR at the end. Without this the synthetic touch lands
  ///    well off-screen on any device with DPR > 1.
  static Offset? _semanticsNodeGlobalCenter(SemanticsNode node) {
    if (node.rect.isEmpty) return null;

    final chain = <SemanticsNode>[];
    SemanticsNode? cur = node;
    while (cur != null) {
      chain.add(cur);
      cur = cur.parent;
    }

    final transform = Matrix4.identity();
    for (final n in chain.reversed) {
      final t = n.transform;
      if (t != null) transform.multiply(t);
    }
    final physical = MatrixUtils.transformPoint(transform, node.rect.center);

    final binding = WidgetsBinding.instance;
    final dpr = binding.platformDispatcher.views.isNotEmpty
        ? binding.platformDispatcher.views.first.devicePixelRatio
        : 1.0;
    return Offset(physical.dx / dpr, physical.dy / dpr);
  }

  static Future<void> _settle() async {
    // Wait for animations/async work to complete
    await Future.delayed(const Duration(milliseconds: 400));
  }

  // ─── Debug shims ──────────────────────────────────────────────────────
  // Expose private helpers to /debug/probe so we can inspect what the
  // bridge thinks a labeled element looks like (rect, computed global
  // centre, action flags) without leaking internals into production.

  static SemanticsNode? debugFindNode({String? elementId, String? label}) {
    return _findNode(elementId: elementId, label: label);
  }

  static Offset? debugGlobalCenter(SemanticsNode node) {
    return _semanticsNodeGlobalCenter(node);
  }

  static SemanticsNode? _findNode({
    String? elementId,
    String? label,
    bool isTextField = false,
  }) {
    final root = WidgetsBinding.instance.pipelineOwner.semanticsOwner?.rootSemanticsNode;
    if (root == null) return null;
    return _searchNode(root, elementId: elementId, label: label, isTextField: isTextField);
  }

  static SemanticsNode? _findScrollable() {
    final root = WidgetsBinding.instance.pipelineOwner.semanticsOwner?.rootSemanticsNode;
    if (root == null) return null;
    return _searchScrollable(root);
  }

  static SemanticsNode? _searchNode(
    SemanticsNode node, {
    String? elementId,
    String? label,
    bool isTextField = false,
  }) {
    final data = node.getSemanticsData();
    final nodeLabel = data.label;

    // Recurse FIRST so we prefer the deepest matching node. Material's
    // FormField wraps a TextField in nested Semantics — both layers carry
    // the same label and the isTextField flag, but only the inner-most one
    // installs a SemanticsAction.setText handler. Returning the outer
    // wrapper makes setText a silent no-op and routes typed text through
    // whatever has keyboard focus (usually the previously-edited field).
    SemanticsNode? deeper;
    node.visitChildren((child) {
      deeper = _searchNode(child, elementId: elementId, label: label, isTextField: isTextField);
      return deeper == null;
    });
    if (deeper != null) return deeper;

    // No match below — try this node.
    if (isTextField) {
      // For typing, require setText capability so we never target a wrapper
      // that can't actually accept text. Per-line label match for the same
      // reason as the tap path: nested-Semantics widgets produce
      // newline-joined labels.
      if (label != null && _labelMatches(nodeLabel, label) &&
          data.hasAction(SemanticsAction.setText)) {
        return node;
      }
      if (elementId != null && _idMatches(elementId, nodeLabel, node.id) &&
          data.hasAction(SemanticsAction.setText)) {
        return node;
      }
      return null;
    }

    // Tap / long-press / general lookup. Allow per-line match so a search
    // for "Finalizează" hits a node whose label is "Finalizează\nFinalizează"
    // (typical when a custom button widget produces nested Semantics layers
    // — the outer wrapper carries the user-set label and the inner Text
    // produces its own label, and the framework merges them with newlines).
    if (label != null && _labelMatches(nodeLabel, label)) {
      return node;
    }
    if (elementId != null && _idMatches(elementId, nodeLabel, node.id)) {
      return node;
    }
    return null;
  }

  /// True if [searchLabel] equals the full node label OR appears as one
  /// of its newline-separated lines (case-insensitive, trimmed).
  static bool _labelMatches(String nodeLabel, String searchLabel) {
    final search = searchLabel.toLowerCase().trim();
    if (search.isEmpty) return false;
    final node = nodeLabel.toLowerCase().trim();
    if (node == search) return true;
    for (final line in node.split('\n')) {
      if (line.trim() == search) return true;
    }
    return false;
  }

  /// Element-ID match in either form: `<slug>_<nodeId>` (typical) or
  /// any string ending with the suffix `_<nodeId>`.
  static bool _idMatches(String elementId, String nodeLabel, int nodeId) {
    final expectedSuffix = '_$nodeId';
    if (elementId.endsWith(expectedSuffix)) return true;
    if (nodeLabel.isNotEmpty) {
      final slug = nodeLabel
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9]'), '_')
          .replaceAll(RegExp(r'_+'), '_');
      if (slug.isNotEmpty && elementId.startsWith(slug)) return true;
    }
    return false;
  }

  static SemanticsNode? _searchScrollable(SemanticsNode node) {
    final data = node.getSemanticsData();
    if (data.hasAction(SemanticsAction.scrollDown) ||
        data.hasAction(SemanticsAction.scrollUp)) {
      return node;
    }
    SemanticsNode? found;
    node.visitChildren((child) {
      found = _searchScrollable(child);
      return found == null;
    });
    return found;
  }
}
