#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Shepit Persistent Recognition Worker
Підтримує:
1. Локальну модель NVIDIA Parakeet TDT 0.6B v3 у пам'яті Apple Silicon (MLX) — 100% офлайн.
2. Гібридну автопідстраховку проблемних слів та брендів через Groq (whisper-large-v3).
3. Роботу на чистому Маці навіть до встановлення parakeet-mlx (через системний Python + Groq).
Протокол: JSON Lines (stdin -> stdout), діагностика -> stderr.
"""

import io
import json
import math
import os
import re
import struct
import subprocess
import sys
import time
import traceback
import urllib.error
import urllib.request
import uuid
import wave
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FuturesTimeout
from pathlib import Path

EXTRA_PATHS = [
    "/opt/homebrew/bin",
    "/usr/local/bin",
    os.path.expanduser("~/.local/bin"),
    os.path.expanduser("~/.cargo/bin"),
]
os.environ["PATH"] = ":".join(EXTRA_PATHS + [os.environ.get("PATH", "/usr/bin:/bin")])

HAS_MLX = False
try:
    import mlx.core as mx
    import numpy as np
    from parakeet_mlx import DecodingConfig, Greedy, SentenceConfig, from_pretrained
    from parakeet_mlx.alignment import (
        merge_longest_common_subsequence,
        merge_longest_contiguous,
        sentences_to_result,
        tokens_to_sentences,
    )
    from parakeet_mlx.audio import get_logmel, load_audio

    HAS_MLX = True
except Exception:
    mx = None
    np = None

DEFAULT_MODEL_DIR = os.path.expanduser("~/.local/share/models/parakeet-tdt-0.6b-v3")
KEYS_DIR = os.path.expanduser("~/.config/keys")

LATIN_RE = re.compile(r"[A-Za-z]")
CYR_RE = re.compile(r"[А-Яа-яІіЇїЄєҐґЁёЫыЭэЪъ]")
UK_SPEC_RE = re.compile(r"[ІіЇїЄєҐґ]")
RU_ONLY_RE = re.compile(r"[ЁёЫыЭэЪъ]")

HALLUCINATION_PATTERNS = [
    re.compile(p, re.IGNORECASE)
    for p in [
        r"дякую за перегляд",
        r"підписуйтесь на канал",
        r"ставте лайк",
        r"субтитри зробив",
        r"субтитри підготував",
        r"редактор субтитрів",
        r"продовження далі",
        r"далі буде",
        r"thank you for watching",
        r"thanks for watching",
        r"subtitles by",
        r"amara\.org",
    ]
]


def log(msg: str) -> None:
    sys.stderr.write(f"[shepit-worker] {msg}\n")
    sys.stderr.flush()


def read_key(name: str, env_var: str = "") -> str:
    if env_var and os.environ.get(env_var, "").strip():
        return os.environ[env_var].strip()
    p = os.path.join(KEYS_DIR, f"{name}.key")
    if os.path.isfile(p):
        try:
            with open(p, "r", encoding="utf-8") as f:
                return f.read().strip()
        except Exception:
            return ""
    return ""


def is_hallucination(text: str) -> bool:
    clean = text.strip()
    if not clean:
        return True
    for pat in HALLUCINATION_PATTERNS:
        if pat.search(clean) and len(clean.split()) <= 8:
            return True
    return False


# --- Pure-Python fallback helpers when numpy/parakeet-mlx is not yet installed ---


def pure_wav_stats_and_bytes(path: str) -> tuple[bytes, float, bool]:
    """Reads WAV (or converts via afconvert/ffmpeg) without numpy for cloud-only mode on fresh Macs."""
    wav_path = path
    tmp_wav = None
    try:
        try:
            with wave.open(path, "rb") as wf:
                ch = wf.getnchannels()
                sw = wf.getsampwidth()
                sr = wf.getframerate()
                n = wf.getnframes()
                if ch == 1 and sw == 2 and sr == 16000:
                    raw = wf.readframes(n)
                    dur = n / 16000.0
                    if n < 3000:
                        return b"", dur, False
                    count = len(raw) // 2
                    shorts = struct.unpack(f"<{count}h", raw)
                    peak = max(abs(x) for x in shorts) / 32768.0 if shorts else 0.0
                    sum_sq = sum((x / 32768.0) ** 2 for x in shorts[::8])
                    rms = math.sqrt(sum_sq / max(1, count // 8))
                    if peak < 0.008 or rms < 0.0022:
                        return b"", dur, False
                    with open(path, "rb") as f:
                        return f.read(), dur, True
        except Exception:
            pass

        tmp_wav = os.path.join("/tmp", f"shepit_conv_{uuid.uuid4().hex}.wav")
        subprocess.run(
            ["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", path, tmp_wav],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        with wave.open(tmp_wav, "rb") as wf:
            dur = wf.getnframes() / float(max(1, wf.getframerate()))
        with open(tmp_wav, "rb") as f:
            return f.read(), dur, dur >= 0.2
    finally:
        if tmp_wav and os.path.exists(tmp_wav):
            try:
                os.remove(tmp_wav)
            except Exception:
                pass


# --- Numpy + MLX signal pipeline ---


def read_wav_fast_16k(path: str):
    try:
        with wave.open(path, "rb") as wf:
            if wf.getnchannels() == 1 and wf.getsampwidth() == 2 and wf.getframerate() == 16000:
                raw = wf.readframes(wf.getnframes())
                return np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    except Exception:
        pass
    return None


def load_samples_16k(path: str):
    arr = read_wav_fast_16k(path)
    if arr is not None:
        return arr
    mx_arr = load_audio(Path(path), 16000, mx.float32)
    return np.array(mx_arr, dtype=np.float32)


def wav_bytes_from_samples(samples, sr: int = 16000) -> bytes:
    clipped = np.clip(samples, -1.0, 1.0)
    pcm = (clipped * 32767.0).astype(np.int16).tobytes()
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sr)
        wf.writeframes(pcm)
    return buf.getvalue()


def preprocess_signal(
    samples,
    sr: int = 16000,
    auto_gain: bool = True,
    dynamic_norm: bool = True,
    silence_removal: bool = True,
):
    if samples.size < int(sr * 0.18):
        return samples, False, 0.0

    samples = samples - float(np.mean(samples))
    frame_len = int(sr * 0.025)
    n_frames = samples.size // frame_len
    if n_frames < 2:
        return samples, False, 0.0

    framed = samples[: n_frames * frame_len].reshape(n_frames, frame_len)
    rms = np.sqrt(np.mean(framed * framed, axis=1) + 1e-12)
    p95 = float(np.percentile(rms, 95))
    p20 = float(np.percentile(rms, 20))
    peak = float(np.max(np.abs(samples)))

    active_threshold = max(0.0032, p20 * 2.4)
    voiced_frames = int(np.sum(rms > active_threshold))
    if p95 < 0.0028 or peak < 0.008 or voiced_frames < 3:
        return samples, False, 0.0

    trim_offset_sec = 0.0
    if silence_removal:
        idx = np.where(rms > active_threshold)[0]
        if idx.size > 0:
            pad_frames = 10
            start_f = max(0, int(idx[0]) - pad_frames)
            end_f = min(n_frames, int(idx[-1]) + pad_frames + 1)
            start_sample = start_f * frame_len
            end_sample = min(samples.size, end_f * frame_len)
            if end_sample - start_sample >= int(sr * 0.2):
                trim_offset_sec = start_sample / sr
                samples = samples[start_sample:end_sample]

    if auto_gain:
        cur_peak = float(np.max(np.abs(samples)))
        if 0.005 < cur_peak < 0.25:
            gain = min(6.5, 0.45 / cur_peak)
            samples = samples * gain

    if dynamic_norm and samples.size >= int(sr * 0.4):
        win = int(sr * 0.2)
        n_w = samples.size // win
        if n_w >= 2:
            w_rms = np.sqrt(
                np.mean(samples[: n_w * win].reshape(n_w, win) ** 2, axis=1) + 1e-8
            )
            target_rms = 0.11
            gains = np.clip(target_rms / np.maximum(w_rms, 0.012), 0.5, 4.5)
            if gains.size >= 3:
                kernel = np.array([0.25, 0.5, 0.25], dtype=np.float32)
                gains = np.convolve(gains, kernel, mode="same")
            centers = (np.arange(n_w) + 0.5) * win
            sample_gains = np.interp(
                np.arange(samples.size), centers, gains
            ).astype(np.float32)
            samples = np.tanh(samples * sample_gains * 1.05) * 0.94
    else:
        samples = np.clip(samples, -0.98, 0.98)

    return samples.astype(np.float32), True, trim_offset_sec


def extract_words(aligned_result) -> list[dict]:
    out = []
    for s in getattr(aligned_result, "sentences", []):
        for t in getattr(s, "tokens", []):
            txt = getattr(t, "text", "")
            start = float(getattr(t, "start", 0.0))
            end = float(getattr(t, "end", start + float(getattr(t, "duration", 0.0))))
            conf = float(getattr(t, "confidence", 1.0))
            if txt.startswith(" ") or not out:
                out.append({"s": round(start, 3), "e": round(end, 3), "w": txt.strip(), "conf": [conf]})
            else:
                out[-1]["w"] += txt
                out[-1]["e"] = round(end, 3)
                out[-1]["conf"].append(conf)
    cleaned = []
    for w in out:
        word_text = w["w"].replace("<unk>", "").strip()
        if word_text:
            cleaned.append(
                {
                    "s": w["s"],
                    "e": w["e"],
                    "w": word_text,
                    "conf": round(min(w["conf"]), 3),
                }
            )
    return cleaned


def detect_language_hint(words: list[dict], requested_lang: str) -> str:
    if requested_lang and requested_lang != "auto":
        return requested_lang
    joined = " ".join(w["w"] for w in words)
    cyr_chars = len(CYR_RE.findall(joined))
    lat_chars = len(LATIN_RE.findall(joined))
    if cyr_chars >= lat_chars and cyr_chars > 0:
        if UK_SPEC_RE.search(joined) or not RU_ONLY_RE.search(joined):
            return "uk"
        return "ru"
    if lat_chars > 0:
        return "en"
    return "uk"


def find_suspicious_windows(words: list[dict], lang_hint: str, conf_thresh: float = 0.78) -> list[tuple[float, float]]:
    if not words:
        return []
    flagged_indices = set()
    total_cyr = sum(1 for w in words if CYR_RE.search(w["w"]))
    mostly_cyrillic = total_cyr >= max(1, int(len(words) * 0.55))

    for i, w in enumerate(words):
        token = w["w"].strip(".,!?…:;«»\"'()—–-")
        if not token:
            continue
        if w["conf"] < conf_thresh:
            flagged_indices.add(i)
        if LATIN_RE.search(token) and CYR_RE.search(token) and re.search(r"[a-zа-яіїєґ]", token):
            flagged_indices.add(i)
        elif mostly_cyrillic and lang_hint in ("uk", "ru") and re.fullmatch(r"[a-z][a-z']*", token):
            flagged_indices.add(i)
        if lang_hint == "uk" and RU_ONLY_RE.search(token):
            flagged_indices.add(i)
        if mostly_cyrillic and len(token) >= 2 and re.fullmatch(r"[А-ЯІЇЄҐ]{2,}", token):
            flagged_indices.add(i)
        if i >= 2 and words[i - 1]["w"].lower() == words[i]["w"].lower() == words[i - 2]["w"].lower():
            flagged_indices.add(i)
            flagged_indices.add(i - 1)
            flagged_indices.add(i - 2)

    if not flagged_indices:
        return []

    pad = 2.0
    join_gap = 1.2
    max_win = 18.0
    raw_spans = []
    for idx in sorted(flagged_indices):
        raw_spans.append((max(0.0, words[idx]["s"] - pad), words[idx]["e"] + pad))

    merged = []
    for a, b in raw_spans:
        if merged and a <= merged[-1][1] + join_gap and (b - merged[-1][0]) <= max_win:
            merged[-1] = (merged[-1][0], max(merged[-1][1], b))
        else:
            merged.append((a, b))
    return merged


def call_groq_whisper(
    wav_bytes: bytes,
    api_key: str,
    language: str,
    vocabulary: list[str],
    timeout_sec: float = 2.6,
) -> str | None:
    if not api_key:
        return None
    boundary = f"----ShepitBoundary{uuid.uuid4().hex}"
    parts: list[bytes] = []

    def add_field(name: str, value: str) -> None:
        parts.append(f"--{boundary}\r\n".encode())
        parts.append(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode())
        parts.append(f"{value}\r\n".encode())

    add_field("model", "whisper-large-v3")
    add_field("response_format", "json")
    add_field("temperature", "0")
    if language and language != "auto":
        add_field("language", language)
    if vocabulary:
        prompt_str = ", ".join(vocabulary[:60])
        add_field("prompt", prompt_str)

    parts.append(f"--{boundary}\r\n".encode())
    parts.append(b'Content-Disposition: form-data; name="file"; filename="clip.wav"\r\n')
    parts.append(b"Content-Type: audio/wav\r\n\r\n")
    parts.append(wav_bytes)
    parts.append(b"\r\n")
    parts.append(f"--{boundary}--\r\n".encode())

    body = b"".join(parts)
    req = urllib.request.Request(
        "https://api.groq.com/openai/v1/audio/transcriptions",
        data=body,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": f"multipart/form-data; boundary={boundary}",
            "User-Agent": "Shepit/1.0",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout_sec) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
            txt = payload.get("text", "").strip()
            if txt and not is_hallucination(txt):
                return txt
    except Exception as exc:
        log(f"Groq whisper fallback skipped: {exc}")
    return None


def apply_llm_postprocess(text: str, llm_mode: str, custom_prompt: str = "") -> tuple[str, bool]:
    if not llm_mode or not text.strip():
        return text, False

    if llm_mode == "clean":
        sys_prompt = (
            "Ти редактор живого диктування. Прибери тільки випадкові обмовки, заїкання, "
            "слова-паразити («ну», «ем», «типу», «коротше» коли вони порожні) та явні самовиправлення "
            "(наприклад «у вівторок, ні, в середу» -> «в середу»). "
            "Збережи мову оригіналу, всі факти, цифри, назви брендів і природний живий голос автора. "
            "Не додавай нічого від себе. Поверни ТІЛЬКИ готовий текст без лапок і коментарів."
        )
    elif llm_mode == "translate_en":
        sys_prompt = (
            "Translate the dictated text into natural, clear, idiomatic English. "
            "Preserve technical terms, brand names, and tone. Return ONLY the translated text without quotes."
        )
    elif llm_mode == "custom" and custom_prompt.strip():
        sys_prompt = custom_prompt.strip() + "\nПоверни ТІЛЬКИ готовий результат без вступних фраз."
    else:
        return text, False

    groq_key = read_key("groq", "GROQ_API_KEY")
    if groq_key:
        try:
            body = json.dumps(
                {
                    "model": "llama-3.3-70b-versatile",
                    "temperature": 0.15,
                    "max_tokens": 2048,
                    "messages": [
                        {"role": "system", "content": sys_prompt},
                        {"role": "user", "content": text},
                    ],
                }
            ).encode("utf-8")
            req = urllib.request.Request(
                "https://api.groq.com/openai/v1/chat/completions",
                data=body,
                headers={
                    "Authorization": f"Bearer {groq_key}",
                    "Content-Type": "application/json",
                    "User-Agent": "Shepit/1.0",
                },
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=4.5) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                out = data["choices"][0]["message"]["content"].strip()
                if out:
                    return out, True
        except Exception as exc:
            log(f"Groq LLM postprocess skipped: {exc}")

    gemini_key = read_key("gemini", "GEMINI_API_KEY")
    if gemini_key:
        try:
            url = f"https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key={gemini_key}"
            body = json.dumps(
                {
                    "systemInstruction": {"parts": [{"text": sys_prompt}]},
                    "contents": [{"parts": [{"text": text}]}],
                    "generationConfig": {"temperature": 0.15},
                }
            ).encode("utf-8")
            req = urllib.request.Request(
                url,
                data=body,
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=5.0) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                out = data["candidates"][0]["content"]["parts"][0]["text"].strip()
                if out:
                    return out, True
        except Exception as exc:
            log(f"Gemini LLM postprocess skipped: {exc}")

    return text, False


def apply_replacements_and_format(
    text: str, replacements: list[dict], autocapitalize: bool
) -> str:
    res = re.sub(r"\s+", " ", text).strip()
    if not res:
        return ""
    for item in replacements:
        src = str(item.get("from", "")).strip()
        dst = str(item.get("to", ""))
        if not src:
            continue
        pattern = re.compile(r"(?<!\w)" + re.escape(src) + r"(?!\w)", re.IGNORECASE)
        res = pattern.sub(dst, res)

    if autocapitalize and res:
        res = res[0].upper() + res[1:]
    return res


class ParakeetWorker:
    def __init__(self, model_dir: str = DEFAULT_MODEL_DIR) -> None:
        self.model_dir = model_dir
        self.model = None
        self.load_time_ms = 0
        self.decoding_config = (
            DecodingConfig(
                decoding=Greedy(),
                sentence=SentenceConfig(max_words=None, silence_gap=None, max_duration=None),
            )
            if HAS_MLX
            else None
        )

    def has_local_model_files(self) -> bool:
        return os.path.isfile(os.path.join(self.model_dir, "model.safetensors"))

    def ensure_loaded(self) -> None:
        if self.model is not None:
            return
        if not HAS_MLX:
            return
        if not self.has_local_model_files():
            return
        t0 = time.perf_counter()
        mx.set_cache_limit(128 * 1024 * 1024)
        self.model = from_pretrained(self.model_dir, dtype=mx.bfloat16)
        dummy = mx.zeros((int(16000 * 0.35),), dtype=mx.float32)
        mel = get_logmel(dummy, self.model.preprocessor_config)
        _ = self.model.generate(mel, decoding_config=self.decoding_config)
        mx.clear_cache()
        self.load_time_ms = int((time.perf_counter() - t0) * 1000)
        log(f"Parakeet v3 loaded & warmed up in {self.load_time_ms} ms")

    def run_samples(self, samples):
        self.ensure_loaded()
        sr = self.model.preprocessor_config.sample_rate
        min_samples = self.model.preprocessor_config.hop_length * 2
        if samples.size < min_samples:
            samples = np.pad(samples, (0, min_samples - samples.size))

        chunk_sec = 60.0
        overlap_sec = 10.0
        if samples.size <= int(chunk_sec * sr):
            mel = get_logmel(mx.array(samples, dtype=mx.float32), self.model.preprocessor_config)
            res = self.model.generate(mel, decoding_config=self.decoding_config)[0]
            mx.clear_cache()
            return res

        chunk_samples = int(chunk_sec * sr)
        overlap_samples = int(overlap_sec * sr)
        all_tokens = []
        for start in range(0, samples.size, chunk_samples - overlap_samples):
            end = min(start + chunk_samples, samples.size)
            if end - start < min_samples:
                break
            chunk_mel = get_logmel(
                mx.array(samples[start:end], dtype=mx.float32),
                self.model.preprocessor_config,
            )
            chunk_res = self.model.generate(chunk_mel, decoding_config=self.decoding_config)[0]
            offset = start / sr
            for sent in chunk_res.sentences:
                for tok in sent.tokens:
                    tok.start += offset
                    tok.end = tok.start + tok.duration
            if all_tokens:
                try:
                    all_tokens = merge_longest_contiguous(
                        all_tokens, chunk_res.tokens, overlap_duration=overlap_sec
                    )
                except RuntimeError:
                    all_tokens = merge_longest_common_subsequence(
                        all_tokens, chunk_res.tokens, overlap_duration=overlap_sec
                    )
            else:
                all_tokens = chunk_res.tokens
            mx.clear_cache()

        return sentences_to_result(
            tokens_to_sentences(all_tokens, self.decoding_config.sentence)
        )

    def handle_preview(self, req: dict) -> dict:
        if not HAS_MLX or not self.has_local_model_files():
            return {"text": ""}
        audio_path = req.get("audio_path", "")
        if not audio_path or not os.path.isfile(audio_path):
            return {"text": ""}
        samples = load_samples_16k(audio_path)
        if samples.size < int(16000 * 0.35):
            return {"text": ""}
        tail_limit = int(16000 * 14.0)
        prefix_ellipsis = samples.size > tail_limit
        if prefix_ellipsis:
            samples = samples[-tail_limit:]
        rms95 = float(np.percentile(np.abs(samples), 95))
        if rms95 < 0.004:
            return {"text": ""}
        res = self.run_samples(samples)
        txt = getattr(res, "text", "").replace("<unk>", "").strip()
        if prefix_ellipsis and txt:
            txt = "… " + txt
        return {"text": txt}

    def handle_transcribe(self, req: dict) -> dict:
        t0 = time.perf_counter()
        audio_path = req.get("audio_path", "")
        if not audio_path or not os.path.isfile(audio_path):
            raise FileNotFoundError(f"Аудіофайл не знайдено: {audio_path}")

        engine = req.get("engine", "hybrid")
        language = req.get("language", "auto")
        auto_gain = bool(req.get("auto_gain", True))
        silence_removal = bool(req.get("silence_removal", True))
        dynamic_norm = bool(req.get("dynamic_normalization", True))
        vocabulary = req.get("vocabulary") or []
        replacements = req.get("replacements") or []
        llm_mode = req.get("llm_mode", "")
        custom_prompt = req.get("custom_prompt", "")
        autocapitalize = bool(req.get("autocapitalize", True))
        is_file = bool(req.get("is_file", False))

        groq_key = read_key("groq", "GROQ_API_KEY")
        local_available = HAS_MLX and self.has_local_model_files()

        # Fresh Mac fallback before local model is installed
        if not local_available:
            if not groq_key:
                raise RuntimeError(
                    "Установіть локальну модель Parakeet v3 або додайте безкоштовний ключ Groq у вкладці «Моделі»."
                )
            wav_data, dur_sec, has_v = pure_wav_stats_and_bytes(audio_path)
            if not has_v:
                return {
                    "no_voice": True,
                    "text": "",
                    "raw_text": "",
                    "duration_sec": round(dur_sec, 3),
                    "processing_ms": int((time.perf_counter() - t0) * 1000),
                    "engine_used": "vad",
                    "groq_assisted": False,
                    "llm_applied": False,
                }
            g_text = call_groq_whisper(
                wav_data, groq_key, language, vocabulary, timeout_sec=30.0 if is_file else 8.0
            )
            if not g_text:
                raise RuntimeError("Groq не відповів — перевірте інтернет або встановіть офлайн-модель Parakeet v3.")
            final_text, llm_applied = apply_llm_postprocess(g_text, llm_mode, custom_prompt)
            final_text = apply_replacements_and_format(final_text, replacements, autocapitalize)
            return {
                "no_voice": False,
                "text": final_text,
                "raw_text": g_text,
                "duration_sec": round(dur_sec, 3),
                "processing_ms": int((time.perf_counter() - t0) * 1000),
                "engine_used": "Groq Whisper v3",
                "groq_assisted": True,
                "llm_applied": llm_applied,
            }

        raw_samples = load_samples_16k(audio_path)
        duration_sec = round(raw_samples.size / 16000.0, 3)

        samples, has_voice, _ = preprocess_signal(
            raw_samples,
            sr=16000,
            auto_gain=auto_gain,
            dynamic_norm=dynamic_norm,
            silence_removal=silence_removal,
        )
        if not has_voice:
            return {
                "no_voice": True,
                "text": "",
                "raw_text": "",
                "duration_sec": duration_sec,
                "processing_ms": int((time.perf_counter() - t0) * 1000),
                "engine_used": "vad",
                "groq_assisted": False,
                "llm_applied": False,
            }

        groq_assisted = False
        engine_used = "Parakeet v3"

        if engine == "groq" and groq_key:
            wav_data = wav_bytes_from_samples(samples, 16000)
            g_text = call_groq_whisper(
                wav_data,
                groq_key,
                language,
                vocabulary,
                timeout_sec=25.0 if is_file else 6.0,
            )
            if g_text:
                raw_text = g_text
                engine_used = "Groq Whisper v3"
                groq_assisted = True
            else:
                res = self.run_samples(samples)
                raw_text = getattr(res, "text", "").replace("<unk>", "").strip()
                engine_used = "Parakeet v3 (офлайн-резерв)"
        else:
            res = self.run_samples(samples)
            words = extract_words(res)
            if not words:
                return {
                    "no_voice": True,
                    "text": "",
                    "raw_text": "",
                    "duration_sec": duration_sec,
                    "processing_ms": int((time.perf_counter() - t0) * 1000),
                    "engine_used": "Parakeet v3",
                    "groq_assisted": False,
                    "llm_applied": False,
                }

            raw_text = " ".join(w["w"] for w in words)

            if engine == "hybrid" and groq_key:
                lang_hint = detect_language_hint(words, language)
                windows = find_suspicious_windows(words, lang_hint)
                if windows:
                    total_audio_sec = samples.size / 16000.0
                    if total_audio_sec <= 20.0 and not is_file:
                        clip_bytes = wav_bytes_from_samples(samples, 16000)
                        g_full = call_groq_whisper(
                            clip_bytes, groq_key, lang_hint, vocabulary, timeout_sec=2.6
                        )
                        if g_full and len(g_full.split()) >= max(1, int(len(words) * 0.78)):
                            raw_text = g_full
                            groq_assisted = True
                            engine_used = "Parakeet v3 + Groq"
                    else:
                        max_windows = 6 if is_file else 2
                        target_windows = windows[:max_windows]
                        win_timeout = 8.0 if is_file else 2.6

                        def query_window(span: tuple[float, float]) -> tuple[int, int, str | None]:
                            inside = [
                                idx
                                for idx, w in enumerate(words)
                                if w["e"] > span[0] and w["s"] < span[1]
                            ]
                            if not inside:
                                return -1, -1, None
                            i0, i1 = inside[0], inside[-1]
                            a_s = max(0, int((words[i0]["s"] - 0.12) * 16000))
                            b_s = min(samples.size, int((words[i1]["e"] + 0.12) * 16000))
                            if b_s - a_s < int(16000 * 0.25):
                                return -1, -1, None
                            clip_bytes = wav_bytes_from_samples(samples[a_s:b_s], 16000)
                            ans = call_groq_whisper(
                                clip_bytes, groq_key, lang_hint, vocabulary, timeout_sec=win_timeout
                            )
                            return i0, i1, ans

                        splices: list[tuple[int, int, str]] = []
                        with ThreadPoolExecutor(max_workers=min(2, len(target_windows))) as pool:
                            futs = [pool.submit(query_window, sp) for sp in target_windows]
                            try:
                                for fut in futs:
                                    i0, i1, g_ans = fut.result(timeout=win_timeout + 0.3)
                                    if i0 >= 0 and g_ans:
                                        splices.append((i0, i1, g_ans))
                            except FuturesTimeout:
                                log("Groq hybrid window timed out, keeping Parakeet")

                        if splices:
                            cur_words = [w["w"] for w in words]
                            for i0, i1, g_txt in sorted(splices, key=lambda x: x[0], reverse=True):
                                pk_count = i1 - i0 + 1
                                g_tokens = g_txt.split()
                                if len(g_tokens) >= max(1, int(pk_count * 0.78)):
                                    cur_words = cur_words[:i0] + g_tokens + cur_words[i1 + 1 :]
                                    groq_assisted = True
                            if groq_assisted:
                                raw_text = " ".join(cur_words)
                                engine_used = "Parakeet v3 + Groq"

        final_text = raw_text
        llm_applied = False
        if llm_mode:
            final_text, llm_applied = apply_llm_postprocess(
                final_text, llm_mode, custom_prompt
            )

        final_text = apply_replacements_and_format(
            final_text, replacements, autocapitalize
        )

        return {
            "no_voice": False,
            "text": final_text,
            "raw_text": raw_text,
            "duration_sec": duration_sec,
            "processing_ms": int((time.perf_counter() - t0) * 1000),
            "engine_used": engine_used,
            "groq_assisted": groq_assisted,
            "llm_applied": llm_applied,
        }

    def status(self) -> dict:
        active_mb = round(mx.get_active_memory() / (1024 * 1024), 1) if HAS_MLX else 0.0
        return {
            "loaded": self.model is not None,
            "model_dir": self.model_dir,
            "model_exists": HAS_MLX and self.has_local_model_files(),
            "load_time_ms": self.load_time_ms,
            "active_memory_mb": active_mb,
            "has_groq_key": bool(read_key("groq", "GROQ_API_KEY")),
            "has_gemini_key": bool(read_key("gemini", "GEMINI_API_KEY")),
        }


def main() -> None:
    worker = ParakeetWorker()
    sys.stdout.write(json.dumps({"event": "started", "status": worker.status()}, ensure_ascii=False) + "\n")
    sys.stdout.flush()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        req_id = ""
        try:
            req = json.loads(line)
            req_id = str(req.get("id", ""))
            cmd = req.get("cmd", "")
            if cmd == "ping":
                res = worker.status()
            elif cmd == "warmup":
                worker.ensure_loaded()
                res = worker.status()
            elif cmd == "preview":
                res = worker.handle_preview(req)
            elif cmd == "transcribe":
                res = worker.handle_transcribe(req)
            elif cmd == "quit":
                sys.stdout.write(json.dumps({"id": req_id, "ok": True}) + "\n")
                sys.stdout.flush()
                break
            else:
                raise ValueError(f"Unknown command: {cmd}")
            out = {"id": req_id, "ok": True, "result": res}
        except Exception as exc:
            log(f"Error handling cmd: {traceback.format_exc()}")
            out = {"id": req_id, "ok": False, "error": str(exc)}

        sys.stdout.write(json.dumps(out, ensure_ascii=False) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
