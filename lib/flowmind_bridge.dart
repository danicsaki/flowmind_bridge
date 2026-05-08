/// FlowMind QA Bridge
/// 
/// Add this to your Flutter app to enable autonomous AI testing.
/// 
/// Usage in main.dart:
/// ```dart
/// import 'package:flowmind_bridge/flowmind_bridge.dart';
/// 
/// void main() {
///   FlowMindBridge.start(); // Call before runApp()
///   runApp(MyApp());
/// }
/// ```
library flowmind_bridge;

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

part 'src/bridge_server.dart';
part 'src/ui_extractor.dart';
part 'src/action_executor.dart';
part 'src/log_collector.dart';
part 'src/field_registry.dart';
