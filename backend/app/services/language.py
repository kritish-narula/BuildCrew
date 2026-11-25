"""TranslationService + SpeechService (STT/TTS). Mock adapters make the app fully runnable
without API keys; Bhashini (Govt. of India, covers all 12 launch languages) and Google adapters
are drop-in replacements selected by TRANSLATION_PROVIDER / SPEECH_PROVIDER.

Pipeline for a work item: customer audio → STT (transcript, customer reviews/edits) →
translate(transcript + text) into each bidding worker's language → TTS on demand.
"""
from abc import ABC, abstractmethod
from pathlib import Path

from ..enums import LANGUAGES

_NATIVE = {lang["code"]: lang["native"] for lang in LANGUAGES}
SAMPLE_AUDIO = Path(__file__).resolve().parent.parent / "assets" / "sample_voice_note.ogg"


class TranslationService(ABC):
    @abstractmethod
    def translate(self, text: str, src: str, tgt: str) -> str: ...


class SpeechService(ABC):
    @abstractmethod
    def transcribe(self, audio: bytes, lang: str) -> str: ...

    @abstractmethod
    def synthesize(self, text: str, lang: str) -> bytes:
        """Returns Opus/OGG bytes."""


class MockTranslation(TranslationService):
    def translate(self, text, src, tgt):
        if src == tgt or not text:
            return text
        return f"[{_NATIVE.get(tgt, tgt)}] {text}"  # visibly mock, but tagged in target script


_MOCK_TRANSCRIPTS = {
    "hi": "बाथरूम में नल से पानी टपक रहा है, और दीवार में सीलन है। पाइप बदलना पड़ेगा।",
    "mr": "बाथरूममध्ये नळ गळतोय आणि भिंतीला ओल आली आहे.",
    "en": "The bathroom tap is leaking and the wall has damp patches. The pipe needs replacing.",
}


class MockSpeech(SpeechService):
    def transcribe(self, audio, lang):
        return _MOCK_TRANSCRIPTS.get(lang, _MOCK_TRANSCRIPTS["hi"])

    def synthesize(self, text, lang):
        return SAMPLE_AUDIO.read_bytes()


class BhashiniAdapter(TranslationService, SpeechService):
    """ULCA pipeline API: (1) getModelsPipeline for task config → (2) compute call to the
    returned inference endpoint. Untested without credentials — validate in Bhashini sandbox."""
    CONFIG_URL = "https://meity-auth.ulcacontrib.org/ulca/apis/v0/model/getModelsPipeline"

    def __init__(self, user_id: str, api_key: str, pipeline_id: str):
        import httpx
        if not (user_id and api_key and pipeline_id):
            raise RuntimeError("Bhashini credentials missing")
        self.http = httpx.Client(timeout=30)
        self.auth = {"userID": user_id, "ulcaApiKey": api_key}
        self.pipeline_id = pipeline_id

    def _run(self, task: str, config: dict, payload: dict) -> dict:
        cfg = self.http.post(self.CONFIG_URL, headers=self.auth, json={
            "pipelineTasks": [{"taskType": task, "config": config}],
            "pipelineRequestConfig": {"pipelineId": self.pipeline_id}}).json()
        ep = cfg["pipelineInferenceAPIEndPoint"]
        service_id = cfg["pipelineResponseConfig"][0]["config"][0]["serviceId"]
        config = {**config, "serviceId": service_id}
        r = self.http.post(ep["callbackUrl"], headers={ep["inferenceApiKey"]["name"]: ep["inferenceApiKey"]["value"]},
                           json={"pipelineTasks": [{"taskType": task, "config": config}], "inputData": payload})
        r.raise_for_status()
        return r.json()["pipelineResponse"][0]

    def translate(self, text, src, tgt):
        if src == tgt:
            return text
        out = self._run("translation", {"language": {"sourceLanguage": src, "targetLanguage": tgt}},
                        {"input": [{"source": text}]})
        return out["output"][0]["target"]

    def transcribe(self, audio, lang):
        import base64
        out = self._run("asr", {"language": {"sourceLanguage": lang}, "audioFormat": "ogg", "samplingRate": 16000},
                        {"audio": [{"audioContent": base64.b64encode(audio).decode()}]})
        return out["output"][0]["source"]

    def synthesize(self, text, lang):
        import base64
        out = self._run("tts", {"language": {"sourceLanguage": lang}, "gender": "female"},
                        {"input": [{"source": text}]})
        return base64.b64decode(out["audio"][0]["audioContent"])


class GoogleAdapter(TranslationService, SpeechService):
    """Google Cloud Translation v2 + Speech-to-Text v1 + Text-to-Speech v1 via REST + API key."""

    def __init__(self, api_key: str):
        import httpx
        if not api_key:
            raise RuntimeError("GOOGLE_API_KEY missing")
        self.key, self.http = api_key, httpx.Client(timeout=30)

    def translate(self, text, src, tgt):
        if src == tgt:
            return text
        r = self.http.post("https://translation.googleapis.com/language/translate/v2",
                           params={"key": self.key}, json={"q": text, "source": src, "target": tgt, "format": "text"})
        r.raise_for_status()
        return r.json()["data"]["translations"][0]["translatedText"]

    def transcribe(self, audio, lang):
        import base64
        r = self.http.post("https://speech.googleapis.com/v1/speech:recognize", params={"key": self.key}, json={
            "config": {"encoding": "OGG_OPUS", "sampleRateHertz": 16000, "languageCode": f"{lang}-IN"},
            "audio": {"content": base64.b64encode(audio).decode()}})
        r.raise_for_status()
        return " ".join(res["alternatives"][0]["transcript"] for res in r.json().get("results", []))

    def synthesize(self, text, lang):
        import base64
        r = self.http.post("https://texttospeech.googleapis.com/v1/text:synthesize", params={"key": self.key}, json={
            "input": {"text": text}, "voice": {"languageCode": f"{lang}-IN"},
            "audioConfig": {"audioEncoding": "OGG_OPUS"}})
        r.raise_for_status()
        return base64.b64decode(r.json()["audioContent"])
