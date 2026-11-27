import 'package:flutter_tts/flutter_tts.dart';

/// Read-aloud. On-device TTS first: zero data, works offline, instant — the right default for
/// workers on prepaid data. (Server TTS via /meta/tts is used for languages the phone lacks;
/// wired in Phase 2 together with the audio player.)
class Speaker {
  Speaker._();
  static final instance = Speaker._();
  final FlutterTts _tts = FlutterTts();

  static const _locales = {
    'hi': 'hi-IN', 'bn': 'bn-IN', 'te': 'te-IN', 'mr': 'mr-IN', 'ta': 'ta-IN', 'gu': 'gu-IN',
    'kn': 'kn-IN', 'ml': 'ml-IN', 'or': 'or-IN', 'pa': 'pa-IN', 'as': 'as-IN', 'en': 'en-IN', 'en_IN': 'en-IN',
  };

  Future<bool> say(String text, String lang) async {
    try {
      await _tts.stop();
      final locale = _locales[lang] ?? 'hi-IN';
      final ok = await _tts.isLanguageAvailable(locale);
      await _tts.setLanguage(ok == true ? locale : 'hi-IN');
      await _tts.setSpeechRate(0.45); // slower than default — clearer for first-time users
      await _tts.speak(text);
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> stop() => _tts.stop();
}
