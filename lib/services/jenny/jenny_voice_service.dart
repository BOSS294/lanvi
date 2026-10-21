// Purpose: Provide on-device TTS fallback, optional Sarvam female Hindi/Hinglish voice, and foreground wake phrase.
// Integration: JennyControlCenterPage only; wake phrase does not run continuously in the background.
// Project: Lanvi | Developer: Mayank Chawdhari AKA BOSS294
// Changelog: Adds Hindi/English speech controls and opt-in Sarvam Bulbul v4 Flash.

import 'dart:convert';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:speech_to_text/speech_to_text.dart';

import 'jenny_native_bridge.dart';
import 'jenny_settings_service.dart';

class JennyVoiceService {
  JennyVoiceService._();
  static final JennyVoiceService instance = JennyVoiceService._();

  final FlutterTts _tts = FlutterTts();
  final SpeechToText _speech = SpeechToText();
  final AudioPlayer _audio = AudioPlayer();
  bool _initialized = false;
  bool _listening = false;

  bool get listening => _listening;

  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    final settings = JennySettingsService.instance;
    if (settings.get<String>('voiceProvider') == 'sarvam') {
      final key = await JennyNativeBridge.instance.readSecret('sarvam');
      if (key != null && key.isNotEmpty) {
        try {
          await _speakSarvam(text, key, settings);
          return;
        } catch (_) {
          // Fail safe to the on-device voice if the optional cloud TTS fails or is offline.
        }
      }
    }
    await _speakLocal(text, settings.get<String>('voiceLanguage'));
  }

  Future<void> _speakSarvam(String text, String key, JennySettingsService settings) async {
    final language = settings.get<String>('voiceLanguage');
    final speaker = settings.get<String>('sarvamSpeaker');
    final response = await http
        .post(
          Uri.parse('https://api.sarvam.ai/text-to-speech'),
          headers: <String, String>{
            'api-subscription-key': key,
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: jsonEncode(<String, Object?>{
            'text': text.substring(0, text.length > 2400 ? 2400 : text.length),
            'language_code': language,
            'model': 'bulbul:v4-flash',
            'speaker': speaker,
            'output_audio_codec': 'mp3',
          }),
        )
        .timeout(const Duration(seconds: 18));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Sarvam voice request failed (${response.statusCode}). Check the optional Sarvam key and voice ID.');
    }
    final decoded = jsonDecode(response.body);
    final audios = decoded is Map ? decoded['audios'] : null;
    if (audios is! List || audios.isEmpty || audios.first is! String) {
      throw Exception('Sarvam did not return audio.');
    }
    final bytes = Uint8List.fromList(base64Decode(audios.first as String));
    await _audio.stop();
    await _audio.play(BytesSource(bytes, mimeType: 'audio/mpeg'));
  }

  Future<void> _speakLocal(String text, String language) async {
    await _tts.awaitSpeakCompletion(true);
    await _tts.setLanguage(language);
    await _tts.setSpeechRate(0.46);
    await _tts.setPitch(1.02);
    await _tts.setVolume(1.0);
    await _tts.speak(text);
  }

  Future<bool> startForegroundWakePhrase({
    required void Function(String command) onWake,
    required void Function(String message) onError,
  }) async {
    if (!_initialized) {
      _initialized = await _speech.initialize(
        onStatus: (status) {
          if (status == 'notListening') _listening = false;
        },
        onError: (error) {
          _listening = false;
          onError(error.errorMsg);
        },
      );
    }
    if (!_initialized) {
      onError('Speech recognition is unavailable. Check microphone and speech-recognition permissions.');
      return false;
    }
    if (_listening) await _speech.stop();
    _listening = true;
    await _speech.listen(
      listenFor: const Duration(seconds: 25),
      partialResults: true,
      localeId: 'en_IN',
      onResult: (result) {
        final words = result.recognizedWords.trim();
        final lower = words.toLowerCase();
        final hit = lower.indexOf('hey jenny');
        if (hit >= 0) {
          final command = words.substring(hit + 'hey jenny'.length).trim();
          _listening = false;
          _speech.stop();
          onWake(command);
        }
      },
    );
    return true;
  }

  Future<void> stopListening() async {
    _listening = false;
    await _speech.stop();
  }

  Future<void> stopSpeaking() async {
    await _tts.stop();
    await _audio.stop();
  }

  Future<void> dispose() async {
    await stopListening();
    await stopSpeaking();
    await _audio.dispose();
  }
}
