// Purpose: Use Groq only for user-initiated assistant chat or locally approved contact messages.
// Integration: Called from JennyControlCenterPage after local policy gating.
// Project: Lanvi | Developer: Mayank Chawdhari AKA BOSS294
// Changelog: Adds live model discovery and a restrictive assistant persona.

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'jenny_native_bridge.dart';
import 'jenny_settings_service.dart';

class JennyModelChoice {
  const JennyModelChoice({required this.id, required this.description});
  final String id;
  final String description;
}

class JennyGroqService {
  JennyGroqService._();
  static final JennyGroqService instance = JennyGroqService._();
  final http.Client _client = http.Client();

  static const Map<String, String> _descriptions = <String, String>{
    'openai/gpt-oss-20b': 'Fast, efficient assistant model. Recommended starting point for short conversations.',
    'openai/gpt-oss-120b': 'Higher-capability reasoning model; may use more tokens and cost more.',
    'llama-3.1-8b-instant': 'Low-latency chat model when enabled for your Groq account.',
    'llama-3.3-70b-versatile': 'More capable general assistant when enabled for your account.',
  };

  Future<List<JennyModelChoice>> fetchModels({String? apiKey}) async {
    final key = apiKey?.trim().isNotEmpty == true
        ? apiKey!.trim()
        : (await JennyNativeBridge.instance.readSecret('groq'));
    if (key == null || key.trim().isEmpty) throw Exception('Add your Groq API key in Jenny → AI & Voice first.');

    final response = await _client.get(
      Uri.parse('https://api.groq.com/openai/v1/models'),
      headers: <String, String>{'Authorization': 'Bearer $key', 'Accept': 'application/json'},
    ).timeout(const Duration(seconds: 12));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Groq model catalog failed (${response.statusCode}). Check the key and network.');
    }
    final decoded = jsonDecode(response.body);
    final data = decoded is Map ? decoded['data'] : null;
    if (data is! List) throw Exception('Groq returned an unexpected model catalog.');
    final choices = <JennyModelChoice>[];
    for (final row in data) {
      if (row is! Map) continue;
      final id = row['id']?.toString() ?? '';
      if (id.isEmpty || _looksNonChat(id)) continue;
      choices.add(JennyModelChoice(
        id: id,
        description: _descriptions[id] ?? 'Available in your Groq account. Check provider details for modalities, limits and pricing.',
      ));
    }
    choices.sort((a, b) => a.id.compareTo(b.id));
    if (choices.isEmpty) throw Exception('No chat models were returned by Groq for this key.');
    return choices;
  }

  String _truncate(String value, int maxLength) =>
      value.length <= maxLength ? value : value.substring(0, maxLength);

  bool _looksNonChat(String id) {
    final value = id.toLowerCase();
    return value.contains('whisper') || value.contains('orpheus') || value.contains('guard') ||
        value.contains('embedding') || value.contains('tts') || value.contains('speech');
  }

  Future<String> answer({
    required String userMessage,
    required String model,
    required String approvedContext,
    String assistantName = 'Jenny',
    List<Map<String, String>> history = const <Map<String, String>>[],
  }) async {
    final key = await JennyNativeBridge.instance.readSecret('groq');
    if (key == null || key.isEmpty) throw Exception('Jenny has no Groq API key saved on this device.');
    final safeAssistantName = assistantName.trim().isEmpty ? 'Jenny' : assistantName.trim().substring(0, assistantName.trim().length > 40 ? 40 : assistantName.trim().length);
    final prompt = '''You are $safeAssistantName, Mayank Chawdhari's AI personal assistant.

STRICT RULES:
- You are an AI assistant, never claim to be a human.
- Your purpose is to communicate Mayank's status and answer project/professional questions only using APPROVED CONTEXT below.
- Never disclose API keys, credentials, addresses, private conversations, personal information, or anything not explicitly present in APPROVED CONTEXT.
- If a request is outside the approved context, politely say you cannot share that and can pass a message to Mayank.
- Keep replies concise (usually 1-4 sentences). Use Hindi, English, or Hinglish to match the message.
- Do not claim that you sent a call, SMS, WhatsApp message, woke Mayank, or completed a task unless the app confirms it.

APPROVED CONTEXT:
${approvedContext.trim()}
''';
    final messages = <Map<String, String>>[
      <String, String>{'role': 'system', 'content': prompt},
      ...history.take(6).map((item) => <String, String>{
            'role': item['role'] == 'assistant' ? 'assistant' : 'user',
            'content': _truncate(item['content'] ?? '', 1200),
          }),
      <String, String>{'role': 'user', 'content': userMessage.trim()},
    ];
    final response = await _client
        .post(
          Uri.parse('https://api.groq.com/openai/v1/chat/completions'),
          headers: <String, String>{
            'Authorization': 'Bearer $key',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(<String, Object?>{
            'model': model,
            'messages': messages,
            'temperature': 0.25,
            'max_tokens': 180,
            'stream': false,
          }),
        )
        .timeout(const Duration(seconds: 18));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Groq request failed (${response.statusCode}). Check the selected model or key.');
    }
    final decoded = jsonDecode(response.body);
    final choices = decoded is Map ? decoded['choices'] : null;
    if (choices is! List || choices.isEmpty || choices.first is! Map) {
      throw Exception('Groq returned no assistant message.');
    }
    final message = (choices.first as Map)['message'];
    final content = message is Map ? message['content']?.toString().trim() : null;
    if (content == null || content.isEmpty) throw Exception('Jenny received an empty response.');
    return content;
  }
}
