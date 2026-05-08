# flowmind_bridge

Embed in your Flutter app to enable autonomous AI-driven QA testing via the
[FlowMind QA](https://github.com/danicsaki/flowmind_bridge) agent.

The bridge runs a localhost HTTP server on port `9999` — **debug builds only,
stripped from release binaries by the Dart compiler** — that exposes the app's
semantics tree and an action dispatch endpoint for an external test agent to
drive the UI.

## What it provides

| Endpoint              | Purpose                                                           |
| --------------------- | ----------------------------------------------------------------- |
| `GET /ping`           | Health check — returns `{"status": "ok"}`                         |
| `GET /ui_state`       | Current screen as JSON (semantics tree, route, navigation state)  |
| `POST /action/tap`    | Tap a labelled widget (semantics action + pointer event fallback) |
| `POST /action/type`   | Write text into a `TextEditingController`                         |
| `POST /action/scroll` | Scroll the focused scrollable                                     |
| `POST /action/back`   | `Navigator.pop()`                                                 |
| `GET /screenshot`     | Current frame as a base64 PNG                                     |
| `GET /logs`           | Flutter framework logs since last drain                           |
| `GET /debug/*`        | Diagnostic endpoints — see _Debugging_ below                      |

## Install

```bash
flutter pub add flowmind_bridge
```

## Usage

### 1. Wire it up in `main.dart`

```dart
import 'package:flowmind_bridge/flowmind_bridge.dart';
import 'package:flutter/material.dart';

final navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Debug-only: assert(...) is stripped by the Dart compiler in release builds,
  // so the bridge HTTP server never starts in production binaries.
  assert(() {
    FlowMindBridge.start(navigatorKey: navigatorKey);
    return true;
  }());

  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,  // required so the bridge can pop routes
      // ...
    );
  }
}
```

### 2. Add `Semantics` labels to interactive widgets

The bridge identifies UI elements through Flutter's accessibility semantics
tree. Every interactive widget needs a label.

```dart
Semantics(
  label: 'Login',
  button: true,
  onTap: _login,                 // wire onTap on Semantics, NOT just InkWell
  child: ElevatedButton(
    onPressed: _login,
    child: const Text('Login'),
  ),
)
```

Why `onTap:` on the `Semantics`: a tap action fires the `Semantics(onTap:)`
callback, not the inner `InkWell.onTap`. If they're different functions
(or the inner one isn't reachable from the semantics action), the bridge
appears to fire taps that nothing responds to.

### 3. Make form input reliable with `FlowMindFieldRegistry`

Material's `TextFormField` produces multiple nested `Semantics` layers; targeting
the right one via the semantics tree is fragile. The cleanest fix is for your
custom input widget to register its `TextEditingController` directly with the
bridge:

```dart
class _MyInputState extends State<MyInput> {
  @override
  void initState() {
    super.initState();
    assert(() {
      FlowMindFieldRegistry.register(widget.hintText, widget.controller);
      return true;
    }());
  }

  @override
  void dispose() {
    assert(() {
      // Pass the controller — registry only deletes the entry if it's
      // ours. Without this, navigating between screens that share a
      // hintText (e.g. "Email" on both /login and /register) races,
      // and disposes accidentally clobber the active screen's controller.
      FlowMindFieldRegistry.unregister(widget.hintText, widget.controller);
      return true;
    }());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: widget.controller,
      decoration: InputDecoration(labelText: widget.hintText),
    );
  }
}
```

Once registered, `POST /action/type` with `{"label": "Email", "text": "..."}`
writes directly to the registered controller, bypassing the semantics tree
entirely.

## Verifying the integration

Run your app in debug mode:

```bash
flutter run --debug
```

You should see in the console:

```
[FlowMindBridge] FlowMind QA Bridge started on http://localhost:9999
```

Then test from another terminal:

```bash
curl http://localhost:9999/ping
# → {"status": "ok", "bridge": "FlowMind QA"}

curl http://localhost:9999/ui_state | jq .
# → JSON of the current screen's elements

curl http://localhost:9999/debug/registry
# → list of TextEditingControllers currently registered
```

If you're testing on an Android emulator, forward the bridge port to the host:

```bash
adb reverse tcp:9999 tcp:9999
```

iOS Simulator shares the host's loopback — no forwarding needed.

## Debugging

When the bridge behaves unexpectedly, four endpoints help isolate the cause:

- **`GET /debug/probe?label=<text>`** — what does the bridge see for a labelled
  element? Returns rect, computed global centre, semantic action flags.
  Useful when a tap appears to fire but nothing happens — usually reveals
  `has_tap_action: false`, meaning the widget needs `Semantics(onTap: ...)`.

- **`GET /debug/last_tap`** — details of the most recent tap dispatch
  (matched node, rect, dispatch method, success).

- **`GET /debug/last_extract_error`** — when `/ui_state` returns
  `screen_id: "transitioning_screen"`, this endpoint shows the actual
  exception thrown by the UI extractor (with stack trace).

- **`GET /debug/registry`** — every key currently registered in
  `FlowMindFieldRegistry`. Useful when typing falls through to the slower
  semantics path.

## Security

The bridge starts only inside an `assert(() { ... ; return true; }())` block,
which Dart's compiler **strips entirely** from release/profile builds. No HTTP
server runs in production binaries. The bridge only listens on `127.0.0.1`
(loopback) and is unreachable from outside the device.

If you want extra paranoia, gate the `assert` further:

```dart
assert(() {
  if (const bool.fromEnvironment('FLOWMIND_BRIDGE')) {
    FlowMindBridge.start(navigatorKey: navigatorKey);
  }
  return true;
}());
```

then opt in only via `flutter run --dart-define=FLOWMIND_BRIDGE=true`.

## Compatibility

- **Flutter:** 3.10.0 or newer
- **Dart SDK:** 3.0.0 or newer
- **Platforms:** Android, iOS (Linux/Web/Windows/macOS untested)

## License

MIT — see [LICENSE](LICENSE).
