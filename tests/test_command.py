import importlib.machinery
import importlib.util
import io
import unittest
from contextlib import redirect_stderr
from pathlib import Path


COMMAND_PATH = Path(__file__).resolve().parents[1] / "scripts" / "omarchy-defthis"


def load_command():
    loader = importlib.machinery.SourceFileLoader("omarchy_defthis_command", str(COMMAND_PATH))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class CommandTests(unittest.TestCase):
    def setUp(self):
        self.command = load_command()
        self.calls = []
        self.pauses = []

    def runner(self, arguments):
        self.calls.append(list(arguments))
        return True

    def test_selection_mode_only_summons_selection_capture(self):
        self.assertEqual(self.command.main(["selection"], self.runner, self.pauses.append), 0)
        self.assertEqual(self.calls, [self.command.SUMMON_COMMAND])
        self.assertEqual(self.pauses, [])

    def test_cursor_mode_selects_word_before_summoning(self):
        self.assertEqual(self.command.main(["cursor"], self.runner, self.pauses.append), 0)
        self.assertEqual(self.calls[:4], [
            ["hyprctl", "dispatch", self.command.key_state_expression("CTRL", "RIGHT", "down")],
            ["hyprctl", "dispatch", self.command.key_state_expression("CTRL", "RIGHT", "up")],
            ["hyprctl", "dispatch", self.command.key_state_expression("CTRL + SHIFT", "LEFT", "down")],
            ["hyprctl", "dispatch", self.command.key_state_expression("CTRL + SHIFT", "LEFT", "up")],
        ])
        self.assertEqual(self.calls[4], self.command.SUMMON_COMMAND)
        self.assertEqual(self.pauses, [
            self.command.KEY_HOLD_SECONDS,
            self.command.BETWEEN_CHORDS_SECONDS,
            self.command.KEY_HOLD_SECONDS,
            self.command.SELECTION_SETTLE_SECONDS,
        ])

    def test_cursor_mode_releases_key_and_opens_overlay_after_failure(self):
        def failing_runner(arguments):
            self.calls.append(list(arguments))
            return len(self.calls) != 1

        self.assertEqual(
            self.command.main(["cursor"], failing_runner, lambda _delay: None),
            1,
        )
        self.assertIn("state = \"up\"", self.calls[1][2])
        self.assertEqual(self.calls[-1], self.command.SUMMON_COMMAND)

    def test_invalid_mode_is_rejected_without_running_commands(self):
        errors = io.StringIO()
        with redirect_stderr(errors):
            result = self.command.main(["unknown"], self.runner, self.pauses.append)
        self.assertEqual(result, 2)
        self.assertIn("usage:", errors.getvalue())
        self.assertEqual(self.calls, [])


if __name__ == "__main__":
    unittest.main()
