#!/usr/bin/env python3

"""Bounded network and cache backend for DefThis."""

from __future__ import annotations

import html
import json
import os
import secrets
import stat
import subprocess
import sys
from html.parser import HTMLParser
from pathlib import Path
from typing import BinaryIO, Callable
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlparse
from urllib.request import Request, urlopen


MAX_RESPONSE_BYTES = 1024 * 1024
MAX_CACHE_BYTES = 1024 * 1024
MAX_CACHE_ENTRIES = 100
MAX_DEFINITIONS = 8
MAX_DEFINITION_CHARS = 1024
MAX_PART_OF_SPEECH_CHARS = 128
MAX_RESULT_BYTES = 64 * 1024
MAX_SELECTION_BYTES = 1024
READ_CHUNK_BYTES = 64 * 1024
REQUEST_TIMEOUT_SECONDS = 4
CACHE_DIRECTORY_NAME = "omarchy-defthis"
CACHE_FILE_NAME = "cache.json"
API_ROOT = "https://en.wiktionary.org/api/rest_v1/page/definition/"


class ResponseTooLarge(Exception):
    pass


class DefinitionNotFound(Exception):
    pass


class LookupUnavailable(Exception):
    pass


class _PlainTextParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []

    def handle_data(self, data: str) -> None:
        self.parts.append(data)


def plain_text(value: object) -> str:
    parser = _PlainTextParser()
    try:
        parser.feed(str(value or ""))
        parser.close()
        text = "".join(parser.parts)
    except Exception:
        text = str(value or "")
    return " ".join(html.unescape(text).split())


def valid_term(value: object) -> str:
    term = str(value or "").strip()
    if not term or len(term) > 80 or any(character.isspace() for character in term):
        return ""
    return term


def sanitize_definitions(value: object) -> list[dict[str, str]]:
    if not isinstance(value, list):
        return []
    definitions: list[dict[str, str]] = []
    for item in value:
        if not isinstance(item, dict):
            continue
        definition = plain_text(item.get("definition"))[:MAX_DEFINITION_CHARS]
        if not definition:
            continue
        definitions.append({
            "partOfSpeech": str(item.get("partOfSpeech") or "")[:MAX_PART_OF_SPEECH_CHARS],
            "definition": definition,
        })
        if len(definitions) >= MAX_DEFINITIONS:
            break
    return definitions


def definitions_from_payload(payload: object) -> list[dict[str, str]]:
    if not isinstance(payload, dict) or not isinstance(payload.get("en"), list):
        return []
    definitions: list[dict[str, str]] = []
    for entry in payload["en"]:
        if not isinstance(entry, dict) or not isinstance(entry.get("definitions"), list):
            continue
        for sense in entry["definitions"]:
            if not isinstance(sense, dict):
                continue
            definition = plain_text(sense.get("definition"))[:MAX_DEFINITION_CHARS]
            if not definition:
                continue
            definitions.append({
                "partOfSpeech": str(entry.get("partOfSpeech") or "")[:MAX_PART_OF_SPEECH_CHARS],
                "definition": definition,
            })
            if len(definitions) >= MAX_DEFINITIONS:
                return definitions
    return definitions


def cache_base_directory() -> Path:
    configured = os.environ.get("XDG_CACHE_HOME", "").strip()
    return Path(configured) if configured else Path.home() / ".cache"


def open_cache_directory(create: bool) -> int | None:
    path = cache_base_directory() / CACHE_DIRECTORY_NAME
    if create:
        try:
            path.mkdir(mode=0o700, parents=True, exist_ok=True)
        except OSError:
            return None
    flags = os.O_RDONLY | os.O_CLOEXEC
    flags |= getattr(os, "O_DIRECTORY", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError:
        return None
    try:
        details = os.fstat(descriptor)
        if not stat.S_ISDIR(details.st_mode):
            os.close(descriptor)
            return None
        os.fchmod(descriptor, 0o700)
        return descriptor
    except OSError:
        os.close(descriptor)
        return None


def open_cache_file(directory_descriptor: int) -> int | None:
    flags = os.O_RDONLY | os.O_CLOEXEC | getattr(os, "O_NONBLOCK", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(CACHE_FILE_NAME, flags, dir_fd=directory_descriptor)
    except OSError:
        return None
    try:
        details = os.fstat(descriptor)
        if not stat.S_ISREG(details.st_mode) or details.st_size > MAX_CACHE_BYTES:
            os.close(descriptor)
            return None
        return descriptor
    except OSError:
        os.close(descriptor)
        return None


def read_bounded_stream(stream: BinaryIO, limit: int) -> bytes:
    result = bytearray()
    while len(result) <= limit:
        remaining = limit + 1 - len(result)
        chunk = stream.read(min(READ_CHUNK_BYTES, remaining))
        if not chunk:
            break
        result.extend(chunk)
        if len(result) > limit:
            raise ResponseTooLarge
    return bytes(result)


def read_bounded_descriptor(descriptor: int, limit: int) -> bytes:
    result = bytearray()
    while len(result) <= limit:
        remaining = limit + 1 - len(result)
        chunk = os.read(descriptor, min(READ_CHUNK_BYTES, remaining))
        if not chunk:
            break
        result.extend(chunk)
        if len(result) > limit:
            raise ResponseTooLarge
    return bytes(result)


def load_cache() -> dict[str, list[dict[str, str]]]:
    directory_descriptor = open_cache_directory(create=False)
    if directory_descriptor is None:
        return {}
    try:
        file_descriptor = open_cache_file(directory_descriptor)
        if file_descriptor is None:
            return {}
        try:
            raw_cache = read_bounded_descriptor(file_descriptor, MAX_CACHE_BYTES)
        except (OSError, ResponseTooLarge):
            return {}
        finally:
            os.close(file_descriptor)
    finally:
        os.close(directory_descriptor)

    try:
        payload = json.loads(raw_cache.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return {}
    if not isinstance(payload, dict) or payload.get("version") not in (1, 2):
        return {}
    entries = payload.get("entries")
    if not isinstance(entries, dict):
        return {}
    bounded: dict[str, list[dict[str, str]]] = {}
    for key, definitions in list(entries.items())[-MAX_CACHE_ENTRIES:]:
        clean_key = valid_term(key).casefold()
        clean_definitions = sanitize_definitions(definitions)
        if clean_key and clean_definitions:
            bounded[clean_key] = clean_definitions
    return bounded


def serialized_cache(entries: dict[str, list[dict[str, str]]]) -> bytes:
    bounded = dict(entries)
    while len(bounded) > MAX_CACHE_ENTRIES:
        bounded.pop(next(iter(bounded)))
    while True:
        encoded = (json.dumps(
            {"version": 1, "entries": bounded},
            ensure_ascii=False,
            separators=(",", ":"),
        ) + "\n").encode("utf-8")
        if len(encoded) <= MAX_CACHE_BYTES or not bounded:
            return encoded
        bounded.pop(next(iter(bounded)))


def write_all(descriptor: int, data: bytes) -> None:
    offset = 0
    while offset < len(data):
        written = os.write(descriptor, data[offset:])
        if written <= 0:
            raise OSError("cache write did not make progress")
        offset += written


def save_cache(entries: dict[str, list[dict[str, str]]]) -> bool:
    directory_descriptor = open_cache_directory(create=True)
    if directory_descriptor is None:
        return False
    temporary_name = f".{CACHE_FILE_NAME}.{os.getpid()}.{secrets.token_hex(8)}.tmp"
    temporary_descriptor: int | None = None
    try:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC
        flags |= getattr(os, "O_NOFOLLOW", 0)
        temporary_descriptor = os.open(
            temporary_name, flags, 0o600, dir_fd=directory_descriptor)
        write_all(temporary_descriptor, serialized_cache(entries))
        os.fsync(temporary_descriptor)
        os.close(temporary_descriptor)
        temporary_descriptor = None
        os.replace(
            temporary_name,
            CACHE_FILE_NAME,
            src_dir_fd=directory_descriptor,
            dst_dir_fd=directory_descriptor,
        )
        os.fsync(directory_descriptor)
        return True
    except OSError:
        return False
    finally:
        if temporary_descriptor is not None:
            os.close(temporary_descriptor)
        try:
            os.unlink(temporary_name, dir_fd=directory_descriptor)
        except OSError:
            pass
        os.close(directory_descriptor)


def validate_wiktionary_response_url(value: str) -> None:
    parsed = urlparse(value)
    if parsed.scheme != "https" or parsed.hostname != "en.wiktionary.org":
        raise LookupUnavailable


def download_json(
    url: str,
    *,
    validate_final_url: bool = True,
    opener: Callable[..., object] = urlopen,
) -> object:
    request = Request(url, headers={
        "Accept": "application/json",
        "Accept-Encoding": "identity",
        "Api-User-Agent": "DefThis/1.0.5 (https://github.com/cbullard/defthis)",
        "User-Agent": "DefThis/1.0.5 (https://github.com/cbullard/defthis)",
    })
    try:
        response = opener(request, timeout=REQUEST_TIMEOUT_SECONDS)
        with response:
            if validate_final_url:
                validate_wiktionary_response_url(response.geturl())
            raw_length = response.headers.get("Content-Length", "")
            try:
                content_length = int(raw_length)
            except (TypeError, ValueError):
                content_length = 0
            if content_length > MAX_RESPONSE_BYTES:
                raise ResponseTooLarge
            data = read_bounded_stream(response, MAX_RESPONSE_BYTES)
    except HTTPError as error:
        if error.code == 404:
            raise DefinitionNotFound from error
        raise LookupUnavailable from error
    except (URLError, TimeoutError, OSError) as error:
        raise LookupUnavailable from error
    try:
        return json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise LookupUnavailable from error


def fetch_definitions(term: str) -> list[dict[str, str]]:
    payload = download_json(API_ROOT + quote(term, safe=""))
    return definitions_from_payload(payload)


def lookup(
    raw_term: object,
    fetcher: Callable[[str], list[dict[str, str]]] = fetch_definitions,
) -> dict[str, object]:
    term = valid_term(raw_term)
    if not term:
        return {"status": "invalid", "cached": False, "definitions": []}
    key = term.casefold()
    cache = load_cache()
    cached_definitions = sanitize_definitions(cache.get(key))
    if cached_definitions:
        return {"status": "ok", "cached": True, "definitions": cached_definitions}

    candidates = [term]
    if key != term:
        candidates.append(key)
    for candidate in candidates:
        try:
            definitions = sanitize_definitions(fetcher(candidate))
        except DefinitionNotFound:
            continue
        except ResponseTooLarge:
            return {"status": "oversized", "cached": False, "definitions": []}
        except LookupUnavailable:
            return {"status": "unavailable", "cached": False, "definitions": []}
        if definitions:
            cache.pop(key, None)
            cache[key] = definitions
            save_cache(cache)
            return {"status": "ok", "cached": False, "definitions": definitions}
    return {"status": "not-found", "cached": False, "definitions": []}


def primary_selection() -> dict[str, object]:
    try:
        process = subprocess.Popen(
            ["wl-paste", "--primary", "--type", "text", "--no-newline"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        return {"status": "error", "selection": ""}
    try:
        if process.stdout is None:
            return {"status": "error", "selection": ""}
        try:
            data = read_bounded_stream(process.stdout, MAX_SELECTION_BYTES)
        except ResponseTooLarge:
            return {"status": "oversized", "selection": ""}
        try:
            exit_code = process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            return {"status": "error", "selection": ""}
        if exit_code != 0:
            return {"status": "error", "selection": ""}
        return {"status": "ok", "selection": data.decode("utf-8", errors="replace")}
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def emit(payload: dict[str, object]) -> None:
    encoded = (json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
    if len(encoded) > MAX_RESULT_BYTES:
        encoded = b'{"status":"error","cached":false,"definitions":[]}\n'
    sys.stdout.buffer.write(encoded)


def main(arguments: list[str]) -> int:
    if len(arguments) == 2 and arguments[0] == "lookup":
        emit(lookup(arguments[1]))
        return 0
    if arguments == ["selection"]:
        emit(primary_selection())
        return 0
    emit({"status": "error", "cached": False, "definitions": []})
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
