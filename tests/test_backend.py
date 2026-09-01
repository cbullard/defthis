import io
import json
import os
import stat
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import DefThisBackend as backend


class _ResponseHandler(BaseHTTPRequestHandler):
    mode = "valid"

    def do_GET(self):
        if self.mode == "declared-oversized":
            self.send_response(200)
            self.send_header("Content-Length", str(backend.MAX_RESPONSE_BYTES + 1))
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        if self.mode == "streamed-oversized":
            chunk = b"x" * backend.READ_CHUNK_BYTES
            try:
                for _ in range(backend.MAX_RESPONSE_BYTES // len(chunk) + 2):
                    self.wfile.write(chunk)
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        self.wfile.write(json.dumps({
            "en": [{
                "partOfSpeech": "Noun",
                "definitions": [{"definition": "A <b>bounded</b> result."}],
            }],
        }).encode())

    def log_message(self, *_args):
        pass


class BackendTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.previous_cache = os.environ.get("XDG_CACHE_HOME")
        os.environ["XDG_CACHE_HOME"] = self.temporary.name

    def tearDown(self):
        if self.previous_cache is None:
            os.environ.pop("XDG_CACHE_HOME", None)
        else:
            os.environ["XDG_CACHE_HOME"] = self.previous_cache

    def cache_directory(self):
        return Path(self.temporary.name) / backend.CACHE_DIRECTORY_NAME

    def test_untrusted_qml_values_are_plain_text(self):
        source = (Path(__file__).resolve().parents[1] / "DefThis.qml").read_text()

        def text_block(binding):
            binding_index = source.index(binding)
            block_start = source.rfind("Text {", 0, binding_index)
            depth = 0
            for index in range(source.index("{", block_start), len(source)):
                if source[index] == "{":
                    depth += 1
                elif source[index] == "}":
                    depth -= 1
                    if depth == 0:
                        return source[block_start:index + 1]
            self.fail(f"Unterminated QML Text block for {binding}")

        for binding in (
            "id: wordTitle",
            "text: root.errorText",
            "text: parent.partOfSpeech",
            "text: parent.definition",
            "text: parent.term",
            "text: parent.partOfSpeech.length",
        ):
            with self.subTest(binding=binding):
                self.assertIn("textFormat: Text.PlainText", text_block(binding))

    def test_parses_and_bounds_definitions(self):
        definitions = backend.definitions_from_payload({
            "en": [{
                "partOfSpeech": "Noun",
                "definitions": [
                    {"definition": "A <a href='/wiki/test'>useful</a> result."},
                ],
            }],
        })
        self.assertEqual(definitions[0]["definition"], "A useful result.")

        many = {"en": [{
            "partOfSpeech": "Noun",
            "definitions": [{"definition": str(index)} for index in range(20)],
        }]}
        self.assertEqual(len(backend.definitions_from_payload(many)), backend.MAX_DEFINITIONS)

    def test_cache_is_owner_only_and_bounded(self):
        entries = {
            f"word-{index}": [{"partOfSpeech": "noun", "definition": "x" * 4000}]
            for index in range(200)
        }
        self.assertTrue(backend.save_cache(entries))
        path = self.cache_directory() / backend.CACHE_FILE_NAME
        self.assertLessEqual(path.stat().st_size, backend.MAX_CACHE_BYTES)
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertLessEqual(len(backend.load_cache()), backend.MAX_CACHE_ENTRIES)

        large_entries = {
            f"large-{index}": [
                {"partOfSpeech": "noun", "definition": "😀" * backend.MAX_DEFINITION_CHARS}
                for _ in range(backend.MAX_DEFINITIONS)
            ]
            for index in range(40)
        }
        self.assertTrue(backend.save_cache(large_entries))
        self.assertLessEqual(path.stat().st_size, backend.MAX_CACHE_BYTES)
        self.assertLess(len(backend.load_cache()), len(large_entries))

    def test_symlink_and_fifo_cache_files_are_rejected(self):
        directory = self.cache_directory()
        directory.mkdir(mode=0o700)
        outside = Path(self.temporary.name) / "outside.json"
        outside.write_text('{"version":1,"entries":{"unsafe":[{"definition":"bad"}]}}')
        cache = directory / backend.CACHE_FILE_NAME
        cache.symlink_to(outside)
        self.assertEqual(backend.load_cache(), {})
        cache.unlink()
        os.mkfifo(cache)
        self.assertEqual(backend.load_cache(), {})

    def test_oversized_regular_file_and_symlink_directory_are_rejected(self):
        directory = self.cache_directory()
        directory.mkdir(mode=0o700)
        cache = directory / backend.CACHE_FILE_NAME
        cache.write_bytes(b"x" * (backend.MAX_CACHE_BYTES + 1))
        self.assertEqual(backend.load_cache(), {})

        cache.unlink()
        directory.rmdir()
        outside = Path(self.temporary.name) / "outside-directory"
        outside.mkdir()
        directory.symlink_to(outside, target_is_directory=True)
        self.assertEqual(backend.load_cache(), {})

    def test_open_descriptor_is_not_changed_by_path_replacement(self):
        self.assertTrue(backend.save_cache({
            "first": [{"partOfSpeech": "noun", "definition": "original"}],
        }))
        directory_descriptor = backend.open_cache_directory(create=False)
        self.assertIsNotNone(directory_descriptor)
        file_descriptor = backend.open_cache_file(directory_descriptor)
        self.assertIsNotNone(file_descriptor)
        replacement = self.cache_directory() / "replacement.json"
        replacement.write_text('{"version":1,"entries":{"second":[{"definition":"replacement"}]}}')
        os.replace(replacement, self.cache_directory() / backend.CACHE_FILE_NAME)
        try:
            raw = backend.read_bounded_descriptor(file_descriptor, backend.MAX_CACHE_BYTES)
        finally:
            os.close(file_descriptor)
            os.close(directory_descriptor)
        self.assertIn(b"original", raw)
        self.assertNotIn(b"replacement", raw)

    def test_lookup_uses_cache_before_network(self):
        backend.save_cache({
            "serendipity": [{"partOfSpeech": "noun", "definition": "Cached."}],
        })

        def unexpected_fetch(_term):
            self.fail("network fetch should not run")

        result = backend.lookup("serendipity", unexpected_fetch)
        self.assertEqual(result["status"], "ok")
        self.assertTrue(result["cached"])

    def test_lookup_retries_lowercase_and_caches_result(self):
        requested = []

        def fetch(term):
            requested.append(term)
            if term == "Serendipity":
                raise backend.DefinitionNotFound
            return [{"partOfSpeech": "noun", "definition": "Found."}]

        result = backend.lookup("Serendipity", fetch)
        self.assertEqual(requested, ["Serendipity", "serendipity"])
        self.assertEqual(result["status"], "ok")
        self.assertFalse(result["cached"])
        self.assertIn("serendipity", backend.load_cache())

    def test_plural_lookup_returns_and_caches_singular_definition(self):
        requested = []
        responses = {
            "children": [
                {"partOfSpeech": "Noun", "definition": "plural of child"},
                {"partOfSpeech": "Noun", "definition": "plural of childer"},
            ],
            "child": [
                {"partOfSpeech": "Noun", "definition": "A young person."},
            ],
        }

        def fetch(term):
            requested.append(term)
            return responses[term]

        result = backend.lookup("children", fetch)
        self.assertEqual(requested, ["children", "child"])
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["term"], "child")
        self.assertEqual(result["definitions"], responses["child"])
        self.assertFalse(result["cached"])

        def unexpected_fetch(_term):
            self.fail("resolved plural should be available offline")

        cached = backend.lookup("children", unexpected_fetch)
        self.assertEqual(cached["term"], "child")
        self.assertEqual(cached["definitions"], responses["child"])
        self.assertTrue(cached["cached"])

    def test_plural_lookup_falls_back_to_plural_entry(self):
        plural_definitions = [
            {"partOfSpeech": "Noun", "definition": "plural of cat"},
            {
                "partOfSpeech": "Verb",
                "definition": "third-person singular present of cat",
            },
        ]

        def fetch(term):
            if term == "cats":
                return plural_definitions
            raise backend.LookupUnavailable

        result = backend.lookup("cats", fetch)
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["term"], "cats")
        self.assertEqual(result["definitions"], plural_definitions)

    def test_verb_form_does_not_trigger_singular_noun_lookup(self):
        requested = []
        definitions = [{
            "partOfSpeech": "Verb",
            "definition": "plural of an imaginary verb",
        }]

        def fetch(term):
            requested.append(term)
            return definitions

        result = backend.lookup("example", fetch)
        self.assertEqual(requested, ["example"])
        self.assertEqual(result["term"], "example")
        self.assertEqual(result["definitions"], definitions)

    def test_cached_legacy_plural_entry_is_upgraded(self):
        backend.save_cache({
            "knives": [{"partOfSpeech": "Noun", "definition": "plural of knife"}],
            "knife": [{"partOfSpeech": "Noun", "definition": "A cutting tool."}],
        })

        def unexpected_fetch(_term):
            self.fail("the singular definition is already cached")

        result = backend.lookup("knives", unexpected_fetch)
        self.assertEqual(result["term"], "knife")
        self.assertEqual(result["definitions"][0]["definition"], "A cutting tool.")
        self.assertTrue(result["cached"])
        _entries, aliases = backend.load_cache_state()
        self.assertEqual(aliases["knives"], "knife")

    def test_primary_selection_is_bounded_before_output(self):
        class FakeProcess:
            def __init__(self, data):
                self.stdout = io.BytesIO(data)
                self.return_code = None

            def wait(self, timeout=None):
                self.return_code = 0
                return 0

            def poll(self):
                return self.return_code

            def terminate(self):
                self.return_code = -15

            def kill(self):
                self.return_code = -9

        with patch.object(backend.subprocess, "Popen", return_value=FakeProcess(b"word")):
            self.assertEqual(backend.primary_selection(), {
                "status": "ok", "selection": "word",
            })
        oversized = b"x" * (backend.MAX_SELECTION_BYTES + 1)
        with patch.object(backend.subprocess, "Popen", return_value=FakeProcess(oversized)):
            self.assertEqual(backend.primary_selection()["status"], "oversized")

    def test_focused_term_prefers_current_accessible_selection(self):
        atspi, desktop, focused_text = self.accessibility_fixture(
            content="alpha current omega",
            caret=8,
            selection=(6, 13),
            word="current",
        )
        result = backend.focused_term(atspi, [desktop])
        self.assertEqual(result, {
            "status": "ok", "term": "current", "source": "selection",
        })
        self.assertEqual(focused_text.string_requests, 0)

    def test_focused_term_uses_word_at_caret_without_selection(self):
        atspi, desktop, _focused_text = self.accessibility_fixture(
            content="alpha current omega",
            caret=8,
            selection=None,
            word="current",
        )
        result = backend.focused_term(atspi, [desktop])
        self.assertEqual(result, {
            "status": "ok", "term": "current", "source": "caret",
        })

    def test_focused_term_uses_indexed_desktop_api(self):
        atspi, desktop, _focused_text = self.accessibility_fixture(
            content="alpha current omega",
            caret=8,
            selection=None,
            word="current",
        )
        atspi.get_desktop_count = lambda: 1
        atspi.get_desktop = lambda index: desktop if index == 0 else None
        result = backend.focused_term(atspi)
        self.assertEqual(result["term"], "current")

    def test_active_window_pid_is_read_from_bounded_hyprctl_output(self):
        class FakeProcess:
            def __init__(self, data):
                self.stdout = io.BytesIO(data)
                self.return_code = None

            def wait(self, timeout=None):
                self.return_code = 0
                return 0

            def poll(self):
                return self.return_code

            def terminate(self):
                self.return_code = -15

            def kill(self):
                self.return_code = -9

        payload = json.dumps({"pid": 4242}).encode()
        with patch.object(backend.subprocess, "Popen", return_value=FakeProcess(payload)):
            self.assertEqual(backend.active_window_pid(), 4242)
        oversized = b"x" * (backend.MAX_ACTIVE_WINDOW_BYTES + 1)
        with patch.object(backend.subprocess, "Popen", return_value=FakeProcess(oversized)):
            self.assertIsNone(backend.active_window_pid())

    def test_active_application_wins_over_stale_focused_selection(self):
        atspi, desktop, _focused_text = self.accessibility_fixture(
            content="alpha current omega",
            caret=8,
            selection=None,
            word="current",
        )
        _other_atspi, stale_desktop, _stale_text = self.accessibility_fixture(
            content="previous",
            caret=2,
            selection=(0, 8),
            word="previous",
        )
        stale_application = stale_desktop.children[0]
        stale_application.pid = 1111
        desktop.children.insert(0, stale_application)
        result = backend.focused_term(
            atspi, [desktop], active_pid=4242)
        self.assertEqual(result, {
            "status": "ok", "term": "current", "source": "caret",
        })

    def accessibility_fixture(self, *, content, caret, selection, word):
        class StateSet:
            def __init__(self, states):
                self.states = states

            def contains(self, state):
                return state in self.states

        class Text:
            def __init__(self):
                self.string_requests = 0

            def get_n_selections(self):
                return int(selection is not None)

            def get_selection(self, _index):
                return type("Range", (), {
                    "start_offset": selection[0], "end_offset": selection[1],
                })()

            def get_text(self, start, end):
                return content[start:end]

            def get_caret_offset(self):
                return caret

            def get_string_at_offset(self, offset, granularity):
                self.string_requests += 1
                self.last_request = (offset, granularity)
                return type("TextRange", (), {"content": word})()

        class Accessible:
            def __init__(self, *, children=(), states=(), text=None, pid=0):
                self.children = list(children)
                self.states = StateSet(set(states))
                self.text = text
                self.pid = pid

            def get_child_count(self):
                return len(self.children)

            def get_child_at_index(self, index):
                return self.children[index]

            def get_state_set(self):
                return self.states

            def is_text(self):
                return self.text is not None

            def get_text_iface(self):
                return self.text

            def get_process_id(self):
                return self.pid

        state_type = type("StateType", (), {
            "ACTIVE": "active", "FOCUSED": "focused",
        })
        granularity = type("TextGranularity", (), {"WORD": "word"})
        fake_atspi = type("Atspi", (), {
            "StateType": state_type, "TextGranularity": granularity,
        })()
        focused_text = Text()
        focused = Accessible(states=("focused",), text=focused_text)
        window = Accessible(children=(focused,), states=("active",))
        application = Accessible(children=(window,), pid=4242)
        desktop = Accessible(children=(application,))
        return fake_atspi, desktop, focused_text

    def run_server_case(self, mode):
        handler = type("CaseHandler", (_ResponseHandler,), {"mode": mode})
        server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return f"http://127.0.0.1:{server.server_port}/definition"

    def test_download_accepts_bounded_response_without_content_length(self):
        payload = backend.download_json(
            self.run_server_case("valid"), validate_final_url=False)
        self.assertEqual(
            backend.definitions_from_payload(payload)[0]["definition"],
            "A bounded result.",
        )

    def test_download_rejects_declared_and_streamed_oversize(self):
        for mode in ("declared-oversized", "streamed-oversized"):
            with self.subTest(mode=mode):
                with self.assertRaises(backend.ResponseTooLarge):
                    backend.download_json(
                        self.run_server_case(mode), validate_final_url=False)


if __name__ == "__main__":
    unittest.main()
