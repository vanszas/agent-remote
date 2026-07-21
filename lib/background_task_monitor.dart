import 'dart:async';

import 'package:flutter/services.dart';

class BackgroundTaskMonitor {
  static const _channel = MethodChannel('agent_remote/monitor');
  static final _openedSessions = StreamController<String>.broadcast();

  static Stream<String> get openedSessions => _openedSessions.stream;

  static Future<void> initialize() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'openSession') {
        final sessionId = call.arguments as String?;
        if (sessionId != null && sessionId.isNotEmpty) {
          _openedSessions.add(sessionId);
        }
      }
    });
    try {
      await _channel.invokeMethod<void>('requestNotificationPermission');
    } on MissingPluginException {
      return;
    }
  }

  static Future<void> start({
    required String tasksUrl,
    required String stopUrl,
    required String token,
    required String sessionId,
    required String title,
    required String agents,
  }) async {
    try {
      await _channel.invokeMethod<void>('start', {
        'tasksUrl': tasksUrl,
        'stopUrl': stopUrl,
        'token': token,
        'sessionId': sessionId,
        'title': title,
        'agents': agents,
      });
    } on MissingPluginException {
      return;
    }
  }

  static Future<void> startCodexSync({
    required String tasksUrl,
    required String token,
  }) async {
    try {
      await _channel.invokeMethod<void>('startSync', {
        'tasksUrl': tasksUrl,
        'token': token,
      });
    } on MissingPluginException {
      return;
    }
  }

  static Future<String?> consumeOpenSession() async {
    try {
      return await _channel.invokeMethod<String>('consumeOpenSession');
    } on MissingPluginException {
      return null;
    }
  }

  static Future<Map<String, String>?> pickNotificationSound() async {
    try {
      final value = await _channel.invokeMapMethod<String, String>(
        'pickNotificationSound',
      );
      return value;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<Map<String, String>?> getNotificationSound() async {
    try {
      return await _channel.invokeMapMethod<String, String>(
        'getNotificationSound',
      );
    } on MissingPluginException {
      return null;
    }
  }

  static Future<void> clearNotificationSound() async {
    try {
      await _channel.invokeMethod<void>('clearNotificationSound');
    } on MissingPluginException {
      return;
    }
  }

  static Future<void> previewNotificationSound() async {
    try {
      await _channel.invokeMethod<void>('previewNotificationSound');
    } on MissingPluginException {
      return;
    }
  }
}
