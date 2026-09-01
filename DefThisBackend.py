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
import time
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
MAX_ACTIVE_WINDOW_BYTES = 64 * 1024
MAX_ACCESSIBLE_NODES = 2048
ACCESSIBILITY_SCAN_SECONDS = 1.0
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


def load_cache_state() -> tuple[
    dict[str, list[dict[str, str]]],
    dict[str, str],
]:
    directory_descriptor = open_cache_directory(create=False)
    if directory_descriptor is None:
        return {}, {}
    try:
        file_descriptor = open_cache_file(directory_descriptor)
        if file_descriptor is None:
            return {}, {}
        try:
            raw_cache = read_bounded_descriptor(file_descriptor, MAX_CACHE_BYTES)
        except (OSError, ResponseTooLarge):
            return {}, {}
        finally:
            os.close(file_descriptor)
    finally:
        os.close(directory_descriptor)

    try:
        payload = json.loads(raw_cache.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return {}, {}
    if not isinstance(payload, dict) or payload.get("version") not in (1, 2):
        return {}, {}
    entries = payload.get("entries")
    if not isinstance(entries, dict):
        return {}, {}
    bounded: dict[str, list[dict[str, str]]] = {}
    for key, definitions in list(entries.items())[-MAX_CACHE_ENTRIES:]:
        clean_key = valid_term(key).casefold()
        clean_definitions = sanitize_definitions(definitions)
        if clean_key and clean_definitions:
            bounded[clean_key] = clean_definitions
    aliases: dict[str, str] = {}
    raw_aliases = payload.get("aliases")
    if isinstance(raw_aliases, dict):
        for key, target in raw_aliases.items():
            clean_key = valid_term(key).casefold()
            clean_target = valid_term(target)
            if clean_key in bounded and clean_target:
                aliases[clean_key] = clean_target
    return bounded, aliases


def load_cache() -> dict[str, list[dict[str, str]]]:
    return load_cache_state()[0]


def serialized_cache(
    entries: dict[str, list[dict[str, str]]],
    aliases: dict[str, str] | None = None,
) -> bytes:
    bounded = dict(entries)
    bounded_aliases = {
        key.casefold(): target
        for key, target in (aliases or {}).items()
        if key.casefold() in bounded and valid_term(target)
    }
    while len(bounded) > MAX_CACHE_ENTRIES:
        removed = next(iter(bounded))
        bounded.pop(removed)
        bounded_aliases.pop(removed, None)
    while True:
        encoded = (json.dumps(
            {"version": 2, "entries": bounded, "aliases": bounded_aliases},
            ensure_ascii=False,
            separators=(",", ":"),
        ) + "\n").encode("utf-8")
        if len(encoded) <= MAX_CACHE_BYTES or not bounded:
            return encoded
        removed = next(iter(bounded))
        bounded.pop(removed)
        bounded_aliases.pop(removed, None)


def write_all(descriptor: int, data: bytes) -> None:
    offset = 0
    while offset < len(data):
        written = os.write(descriptor, data[offset:])
        if written <= 0:
            raise OSError("cache write did not make progress")
        offset += written


def save_cache(
    entries: dict[str, list[dict[str, str]]],
    aliases: dict[str, str] | None = None,
) -> bool:
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
        write_all(temporary_descriptor, serialized_cache(entries, aliases))
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
        "Api-User-Agent": "DefThis/1.2.0 (https://github.com/cbullard/defthis)",
        "User-Agent": "DefThis/1.2.0 (https://github.com/cbullard/defthis)",
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


def singular_lemma(definitions: list[dict[str, str]]) -> str:
    prefix = "plural of "
    for item in definitions:
        if str(item.get("partOfSpeech") or "").casefold() != "noun":
            continue
        definition = str(item.get("definition") or "").strip()
        if not definition.casefold().startswith(prefix):
            continue
        lemma = valid_term(definition[len(prefix):].removesuffix("."))
        if lemma:
            return lemma
    return ""


def fetch_lookup_candidates(
    term: str,
    fetcher: Callable[[str], list[dict[str, str]]],
) -> tuple[str, list[dict[str, str]]]:
    key = term.casefold()
    candidates = [term]
    if key != term:
        candidates.append(key)
    for candidate in candidates:
        try:
            definitions = sanitize_definitions(fetcher(candidate))
        except DefinitionNotFound:
            continue
        except ResponseTooLarge:
            return "oversized", []
        except LookupUnavailable:
            return "unavailable", []
        if definitions:
            return "ok", definitions
    return "not-found", []


def cache_definitions(
    cache: dict[str, list[dict[str, str]]],
    aliases: dict[str, str],
    key: str,
    definitions: list[dict[str, str]],
    resolved_term: str,
) -> None:
    cache.pop(key, None)
    cache[key] = definitions
    if resolved_term.casefold() == key:
        aliases.pop(key, None)
    else:
        aliases[key] = resolved_term


def lookup(
    raw_term: object,
    fetcher: Callable[[str], list[dict[str, str]]] = fetch_definitions,
) -> dict[str, object]:
    term = valid_term(raw_term)
    if not term:
        return {"status": "invalid", "cached": False, "definitions": []}
    key = term.casefold()
    cache, aliases = load_cache_state()
    cached_definitions = sanitize_definitions(cache.get(key))
    if cached_definitions:
        resolved_term = aliases.get(key, "")
        if resolved_term:
            return {
                "status": "ok", "cached": True, "term": resolved_term,
                "definitions": cached_definitions,
            }

        resolved_term = singular_lemma(cached_definitions)
        if not resolved_term:
            return {
                "status": "ok", "cached": True, "term": term,
                "definitions": cached_definitions,
            }

        resolved_key = resolved_term.casefold()
        resolved_definitions = sanitize_definitions(cache.get(resolved_key))
        resolved_from_cache = bool(resolved_definitions)
        if not resolved_definitions:
            _status, resolved_definitions = fetch_lookup_candidates(
                resolved_term, fetcher)
        if resolved_definitions:
            cache_definitions(
                cache, aliases, resolved_key, resolved_definitions, resolved_term)
            cache_definitions(
                cache, aliases, key, resolved_definitions, resolved_term)
            save_cache(cache, aliases)
            return {
                "status": "ok", "cached": resolved_from_cache,
                "term": resolved_term,
                "definitions": resolved_definitions,
            }
        return {
            "status": "ok", "cached": True, "term": term,
            "definitions": cached_definitions,
        }

    status, definitions = fetch_lookup_candidates(term, fetcher)
    if not definitions:
        return {"status": status, "cached": False, "definitions": []}

    resolved_term = singular_lemma(definitions)
    resolved_definitions: list[dict[str, str]] = []
    if resolved_term:
        resolved_key = resolved_term.casefold()
        resolved_definitions = sanitize_definitions(cache.get(resolved_key))
        if not resolved_definitions:
            _status, resolved_definitions = fetch_lookup_candidates(
                resolved_term, fetcher)
        if resolved_definitions:
            cache_definitions(
                cache, aliases, resolved_key, resolved_definitions, resolved_term)
            definitions = resolved_definitions
        else:
            resolved_term = term
    else:
        resolved_term = term

    cache_definitions(cache, aliases, key, definitions, resolved_term)
    save_cache(cache, aliases)
    return {
        "status": "ok", "cached": False, "term": resolved_term,
        "definitions": definitions,
    }


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


def active_window_pid() -> int | None:
    try:
        process = subprocess.Popen(
            ["hyprctl", "activewindow", "-j"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        return None
    try:
        if process.stdout is None:
            return None
        try:
            data = read_bounded_stream(process.stdout, MAX_ACTIVE_WINDOW_BYTES)
            exit_code = process.wait(timeout=1)
        except (ResponseTooLarge, subprocess.TimeoutExpired):
            return None
        if exit_code != 0:
            return None
        payload = json.loads(data.decode("utf-8"))
        pid = int(payload.get("pid", 0)) if isinstance(payload, dict) else 0
        return pid if pid > 0 else None
    except (UnicodeDecodeError, json.JSONDecodeError, TypeError, ValueError):
        return None
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def _children(accessible: object) -> list[object]:
    try:
        count = min(int(accessible.get_child_count()), MAX_ACCESSIBLE_NODES)
    except Exception:
        return []
    children: list[object] = []
    for index in range(max(0, count)):
        try:
            child = accessible.get_child_at_index(index)
        except Exception:
            continue
        if child is not None:
            children.append(child)
    return children


def _has_state(accessible: object, state: object) -> bool:
    try:
        return bool(accessible.get_state_set().contains(state))
    except Exception:
        return False


def _term_at_focused_accessible(
    accessible: object,
    atspi: object,
) -> dict[str, object] | None:
    if not _has_state(accessible, atspi.StateType.FOCUSED):
        return None
    try:
        if not accessible.is_text():
            return None
        text = accessible.get_text_iface()
        selection_count = int(text.get_n_selections())
        for selection_index in range(max(0, selection_count)):
            selected_range = text.get_selection(selection_index)
            start = int(selected_range.start_offset)
            end = int(selected_range.end_offset)
            if end > start:
                return {
                    "status": "ok",
                    "term": text.get_text(start, end),
                    "source": "selection",
                }

        caret = int(text.get_caret_offset())
        if caret < 0:
            return None
        word_range = text.get_string_at_offset(caret, atspi.TextGranularity.WORD)
        return {
            "status": "ok",
            "term": str(word_range.content or ""),
            "source": "caret",
        }
    except Exception:
        return None


def _ordered_accessibility_roots(
    desktops: list[object],
    atspi: object,
    active_pid: int | None,
) -> list[object]:
    roots: list[object] = []
    for desktop in desktops:
        applications = _children(desktop)
        if active_pid is not None:
            active_applications: list[object] = []
            for application in applications:
                try:
                    if int(application.get_process_id()) == active_pid:
                        active_applications.append(application)
                except Exception:
                    continue
            if active_applications:
                for application in active_applications:
                    application_windows = _children(application)
                    roots.extend(application_windows or [application])
                continue

        windows: list[object] = []
        for application in applications:
            application_windows = _children(application)
            windows.extend(application_windows or [application])
        active = [
            window for window in windows
            if _has_state(window, atspi.StateType.ACTIVE)
        ]
        roots.extend(active)
        roots.extend(window for window in windows if window not in active)
    return roots or desktops


def _load_atspi() -> object | None:
    try:
        import gi
        gi.require_version("Gio", "2.0")
        gi.require_version("Atspi", "2.0")
        from gi.repository import Atspi, Gio, GLib

        session_bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        result = session_bus.call_sync(
            "org.a11y.Bus",
            "/org/a11y/bus",
            "org.a11y.Bus",
            "GetAddress",
            None,
            GLib.VariantType.new("(s)"),
            Gio.DBusCallFlags.NONE,
            1000,
            None,
        )
        if not result or not result.unpack()[0]:
            return None
        if not Atspi.is_initialized() and Atspi.init() != 0:
            return None
        return Atspi
    except Exception:
        return None


def focused_term(
    atspi: object | None = None,
    desktops: list[object] | None = None,
    active_pid: int | None = None,
) -> dict[str, object]:
    owns_atspi = atspi is None
    atspi = atspi or _load_atspi()
    if atspi is None:
        return {"status": "unavailable", "term": "", "source": ""}
    try:
        if desktops is None:
            desktops = [
                atspi.get_desktop(index)
                for index in range(max(0, int(atspi.get_desktop_count())))
            ]
            desktops = [desktop for desktop in desktops if desktop is not None]
        if active_pid is None and owns_atspi:
            active_pid = active_window_pid()

        deadline = time.monotonic() + ACCESSIBILITY_SCAN_SECONDS
        visited = 0
        for root in _ordered_accessibility_roots(desktops, atspi, active_pid):
            stack = [root]
            while (stack and visited < MAX_ACCESSIBLE_NODES
                   and time.monotonic() < deadline):
                accessible = stack.pop()
                visited += 1
                result = _term_at_focused_accessible(accessible, atspi)
                if result is not None:
                    return result
                children = _children(accessible)
                stack.extend(reversed(children))
        return {"status": "unavailable", "term": "", "source": ""}
    except Exception:
        return {"status": "unavailable", "term": "", "source": ""}
    finally:
        if owns_atspi:
            try:
                atspi.exit()
            except Exception:
                pass


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
    if arguments == ["focused-term"]:
        emit(focused_term())
        return 0
    emit({"status": "error", "cached": False, "definitions": []})
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
