part of flowmind_bridge;

/// Opt-in registry that maps a human-readable key (typically the field's
/// hint or labelText) to its [TextEditingController].
///
/// Why this exists: Material's `TextFormField` produces multiple Semantics
/// layers carrying the same label, and `SemanticsAction.setText` can route
/// through whichever field has keyboard focus — leading to text landing in
/// the wrong controller. By registering controllers directly, the bridge
/// can write text by direct reference, bypassing semantics entirely.
///
/// Usage in your text field widget:
///
/// ```dart
/// @override
/// void initState() {
///   super.initState();
///   assert(() {
///     FlowMindFieldRegistry.register(widget.hintText, widget.controller);
///     return true;
///   }());
/// }
///
/// @override
/// void dispose() {
///   assert(() {
///     FlowMindFieldRegistry.unregister(widget.hintText);
///     return true;
///   }());
///   super.dispose();
/// }
/// ```
///
/// The `assert(() { ... ; return true; }())` pattern keeps registry calls
/// in debug builds only — the same convention the bridge itself uses, so
/// nothing leaks into release/profile binaries.
class FlowMindFieldRegistry {
  static final Map<String, TextEditingController> _fields =
      <String, TextEditingController>{};

  /// Register a controller under [key]. If [key] already exists the new
  /// controller replaces the old one — handy for screens that rebuild but
  /// keep the same logical field name.
  static void register(String? key, TextEditingController controller) {
    if (key == null || key.isEmpty) return;
    _fields[key] = controller;
  }

  /// Drop a key from the registry — but ONLY if the controller currently
  /// stored under [key] is the same one [owner] passed in (or [owner] is
  /// null, for legacy callers).
  ///
  /// Why the owner check matters: when navigating between screens that
  /// share a hintText (e.g. "Email" or "Parolă" exist on BOTH login and
  /// register), Flutter's lifecycle is:
  ///   1. New screen's InputWidget mounts → register(key, newController)
  ///   2. Old screen's InputWidget disposes (after the route transition
  ///      finishes) → unregister(key)
  /// Without an owner check, step 2 deletes the entry that step 1 just
  /// installed — leaving the registry empty for that key on the new
  /// screen. Subsequent type actions then miss the registry and fall
  /// through to semantics, which often can't find a setText-capable
  /// node on custom input widgets. With the owner check, step 2 sees
  /// `_fields[key] != owner` and is a no-op. Net effect: the new
  /// screen's controller stays registered, typing works.
  static void unregister(String? key, [TextEditingController? owner]) {
    if (key == null) return;
    if (owner != null) {
      final current = _fields[key];
      if (current != owner) {
        // Someone else owns this slot now — leave it alone.
        return;
      }
    }
    _fields.remove(key);
  }

  /// Find a controller by exact match, then case-insensitive, then by
  /// the slugified element-ID prefix (`hint_<nodeId>`-style ids).
  /// Returns null if no field is registered under any matching key.
  static TextEditingController? lookup(String? key) {
    if (key == null || key.isEmpty) return null;
    final direct = _fields[key];
    if (direct != null) return direct;
    final lower = key.toLowerCase();
    for (final entry in _fields.entries) {
      if (entry.key.toLowerCase() == lower) return entry.value;
    }
    // ID-style match: agent might send "email_10"; registry might hold "Email".
    for (final entry in _fields.entries) {
      final slug = entry.key
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9]'), '_')
          .replaceAll(RegExp(r'_+'), '_');
      if (slug.isNotEmpty && lower.startsWith(slug)) return entry.value;
    }
    return null;
  }

  /// Used by tests / diagnostics.
  static List<String> registeredKeys() => _fields.keys.toList(growable: false);

  /// Clear every registered field — primarily for hot-restart scenarios.
  static void clear() => _fields.clear();
}
