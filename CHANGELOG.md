# Changelog

All notable changes to `flowmind_bridge` are documented here.
This project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 1.0.0

First public release.

### Features

* **HTTP bridge on `localhost:9999`** — debug-only via `assert(...)`, stripped from
  release builds by the Dart compiler.
* **`GET /ui_state`** — current screen's semantics tree as JSON, with deduplication
  of nested wrappers (Material's nested `Semantics` layers no longer leak duplicate
  entries for the same logical widget).
* **`POST /action/{tap,type,scroll,back,long_press}`** — UI action dispatch.
  * `tap` fires `SemanticsAction.tap` for accessibility-aware widgets, and falls
    back to a synthetic pointer event at the widget's centre (DPR-corrected for
    high-density displays) for widgets where the semantic action doesn't route
    to `onTap` (BottomNavigationBar items, AlertDialog buttons, custom
    `GestureDetector`s).
  * `type` writes directly to a registered `TextEditingController` when available,
    falling back to `SemanticsAction.setText` otherwise. Per-line label match
    handles widgets whose nested `Semantics` produces newline-joined labels.
* **`GET /screenshot`** — current frame as base64 PNG, captured via
  `OffsetLayer.toImage()` on the root `RenderView` (no host-app integration
  required).
* **`GET /logs`** + **`POST /logs/clear`** — captured Flutter framework logs
  for crash/exception detection.
* **`FlowMindFieldRegistry`** — opt-in registry for reliable form input.
  Register your `TextEditingController` in `initState()` and unregister in
  `dispose()`; the bridge writes directly to your controller, bypassing
  Material's nested `Semantics` layering issues. Owner-aware `unregister`
  prevents race conditions during cross-screen navigation.
* **Diagnostic endpoints** for debugging integration issues:
  * `GET /debug/probe?label=...` — inspect what the bridge sees for a labelled
    element (rect, computed global centre, semantic action flags).
  * `GET /debug/last_tap` — inspect the most recent tap dispatch.
  * `GET /debug/last_extract_error` — last exception thrown by the UI extractor,
    with stack trace, when `/ui_state` returns `transitioning_screen`.
  * `GET /debug/registry` — list every key currently registered in
    `FlowMindFieldRegistry`.
* **Romanian / multilingual support** — labels are matched case-insensitively,
  diacritics are sanitised at the screen-id level but preserved in widget
  labels.
