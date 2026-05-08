part of flowmind_bridge;

class FlowMindBridge {
  static HttpServer? _server;
  static final _logCollector = _LogCollector();
  static GlobalKey<NavigatorState>? navigatorKey;
  static int port = 9999;

  static Future<void> start({
    GlobalKey<NavigatorState>? navigatorKey,
    int port = 9999,
    bool debugLogs = false,
  }) async {
    FlowMindBridge.navigatorKey = navigatorKey;
    FlowMindBridge.port = port;

    _logCollector.attach();

    try {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      _log('FlowMind QA Bridge started on http://localhost:$port');
      _handleRequests();
    } catch (e) {
      _log('FlowMind QA Bridge failed to start: $e');
    }
  }

  static Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  static void _log(String msg) {
    developer.log(msg, name: 'FlowMindBridge');
  }

  static void _handleRequests() {
    _server?.listen((HttpRequest request) async {
      request.response.headers
          .add('Content-Type', 'application/json; charset=utf-8');
      request.response.headers.add('Access-Control-Allow-Origin', '*');

      try {
        final path = request.uri.path;
        final method = request.method;

        if (method == 'GET' && path == '/ping') {
          _respond(request, {'status': 'ok', 'bridge': 'FlowMind QA'});
        } else if (method == 'GET' && path == '/ui_state') {
          try {
            final state = await _UIExtractor.extractState();
            _respond(request, state);
          } catch (e, stack) {
            // Surface the failure: log to flutter console so the dev sees
            // it during `flutter run`, stash the latest one for retrieval
            // via /debug/last_extract_error, and include the message in
            // the JSON response itself rather than the previous opaque
            // 'extraction_failed' string.
            _log('[ui_state] extractor threw: $e');
            _log('[ui_state] stack:\n$stack');
            _UIExtractor.lastError = {
              'error': e.toString(),
              'stack': stack.toString(),
              'timestamp': DateTime.now().millisecondsSinceEpoch,
            };
            _respond(request, {
              'screen_id': 'transitioning_screen',
              'elements': [],
              'navigation': {'can_go_back': false},
              'error': 'extraction_failed',
              'error_detail': e.toString(),
            });
          }
        } else if (method == 'GET' && path == '/debug/last_extract_error') {
          // Diagnostic: return the most recent exception thrown by
          // _UIExtractor.extractState(). Useful when /ui_state keeps
          // returning {screen_id: 'transitioning_screen'} for a screen
          // you expect to have content — that response means the
          // extractor crashed and this endpoint shows what crashed it.
          _respond(request, _UIExtractor.lastError);
        } else if (method == 'GET' && path == '/debug/last_tap') {
          // Diagnostic: returns details about the most recent /action/tap.
          // Useful when the agent reports `success: true` but the screen
          // doesn't change — lets us verify which node was matched, what
          // global centre was computed, and whether both dispatch paths
          // (SemanticsAction + pointer events) actually fired.
          _respond(request, _ActionExecutor.lastTap);
        } else if (method == 'GET' && path == '/debug/registry') {
          // Diagnostic: list every key currently registered in
          // FlowMindFieldRegistry. Useful for checking whether a custom
          // input widget's hintText is what the agent should target.
          _respond(request, {
            'registered_keys': FlowMindFieldRegistry.registeredKeys(),
            'count': FlowMindFieldRegistry.registeredKeys().length,
          });
        } else if (method == 'GET' && path.startsWith('/debug/probe')) {
          // Diagnostic: return the bridge's view of a specific element.
          // Usage: /debug/probe?label=Legi
          //
          // Reports: matched node id, local rect, computed global centre,
          // and the screen size we'd hit-test against. Lets us verify
          // whether tap coordinates are sensible (inside the screen, on
          // the actual widget) when a tap silently does nothing.
          final query = request.uri.queryParameters;
          final label = query['label'];
          final elementId = query['element_id'];
          final result = <String, dynamic>{};
          try {
            final node = _ActionExecutor.debugFindNode(
              elementId: elementId,
              label: label,
            );
            if (node == null) {
              result['found'] = false;
            } else {
              final centre = _ActionExecutor.debugGlobalCenter(node);
              final binding = WidgetsBinding.instance;
              final viewSize = binding.renderViews.isNotEmpty
                  ? binding.renderViews.first.size
                  : null;
              result['found'] = true;
              result['node_id'] = node.id;
              result['label'] = node.getSemanticsData().label;
              result['rect_local'] = {
                'x': node.rect.left,
                'y': node.rect.top,
                'w': node.rect.width,
                'h': node.rect.height,
              };
              result['global_center'] =
                  centre == null ? null : {'x': centre.dx, 'y': centre.dy};
              result['screen_size'] = viewSize == null
                  ? null
                  : {'w': viewSize.width, 'h': viewSize.height};
              result['has_tap_action'] =
                  node.getSemanticsData().hasAction(SemanticsAction.tap);
              result['flags'] = {
                'isButton':
                    node.getSemanticsData().hasFlag(SemanticsFlag.isButton),
                'isLink': node.getSemanticsData().hasFlag(SemanticsFlag.isLink),
                'isHidden':
                    node.getSemanticsData().hasFlag(SemanticsFlag.isHidden),
              };
            }
          } catch (e) {
            result['error'] = e.toString();
          }
          _respond(request, result);
        } else if (method == 'GET' && path == '/logs') {
          _respond(request, {'logs': _logCollector.drain()});
        } else if (method == 'POST' && path == '/logs/clear') {
          _logCollector.clear();
          _respond(request, {'cleared': true});
        } else if (method == 'GET' && path == '/screenshot') {
          try {
            // Capture the root view as PNG. RenderView reports
            // isRepaintBoundary == true and owns an OffsetLayer (its
            // TransformLayer extends OffsetLayer), so we go through the
            // layer rather than casting the render object — avoids the
            // class-vs-property mismatch where RenderView is a repaint
            // boundary but does NOT inherit from RenderRepaintBoundary.
            // pixelRatio 1.5 balances legibility vs image-token cost.
            final binding = WidgetsBinding.instance;
            if (binding.renderViews.isEmpty) {
              _respond(
                  request, {'data': null, 'error': 'No render views attached'});
            } else {
              final RenderObject root = binding.renderViews.first;
              final layer = root.debugLayer;
              if (layer is! OffsetLayer) {
                _respond(request, {
                  'data': null,
                  'error':
                      'Root layer is not an OffsetLayer (got ${layer.runtimeType})',
                });
              } else {
                final ui.Image image = await layer.toImage(
                  root.paintBounds,
                  pixelRatio: 1.5,
                );
                final byteData =
                    await image.toByteData(format: ui.ImageByteFormat.png);
                image.dispose();
                if (byteData == null) {
                  _respond(
                      request, {'data': null, 'error': 'PNG encode failed'});
                } else {
                  final b64 = base64Encode(byteData.buffer.asUint8List());
                  _respond(request, {'data': b64, 'format': 'png'});
                }
              }
            }
          } catch (e) {
            _respond(request, {'data': null, 'error': e.toString()});
          }
        } else if (method == 'POST' && path.startsWith('/action/')) {
          final body = await _readBody(request);
          final result = await _ActionExecutor.execute(path, body);
          _respond(request, result);
        } else {
          request.response.statusCode = 404;
          _respond(request, {'error': 'Not found: $path'});
        }
      } catch (e) {
        try {
          request.response.statusCode = 500;
          // Only use ASCII-safe error message
          final safeError = e
              .toString()
              .replaceAll(RegExp(r'[^\x00-\x7F]'), '?')
              .substring(
                  0, e.toString().length > 200 ? 200 : e.toString().length);
          _respond(request, {'error': safeError});
        } catch (_) {
          request.response.statusCode = 500;
          request.response.write('{"error":"internal error"}');
          request.response.close();
        }
      }
    });
  }

  static void _respond(HttpRequest request, Map<String, dynamic> data) {
    try {
      // Use explicit UTF-8 encoding and verify the JSON is valid ASCII-safe
      final jsonStr = jsonEncode(data);
      request.response.write(jsonStr);
    } catch (e) {
      // Fallback: return a safe error response
      request.response
          .write('{"error":"encoding_error","screen_id":"unknown"}');
    }
    request.response.close();
  }

  static Future<Map<String, dynamic>> _readBody(HttpRequest request) async {
    final bytes = await request.fold<List<int>>([], (a, b) => [...a, ...b]);
    if (bytes.isEmpty) return {};
    return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  }
}
