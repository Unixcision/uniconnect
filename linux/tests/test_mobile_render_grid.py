"""Pure capture-to-render-grid contract tests; run in CI, not local desktop sessions."""

import json
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from uniconnect.mobile_render_grid import (CaptureRenderError, capture_dependencies_ready,
                                          render_grid_from_tmux_capture)


# Deliberately injected fixture colors, not a claim about VTE's system palette.
PALETTE = ("#000000", "#c11c22", "#26a269", "#a2734c", "#12488b", "#a347ba", "#2aa1b3", "#d0cfcc",
           "#5e5c64", "#f66151", "#33d17a", "#e9ad0c", "#2a7bde", "#c061cb", "#33c7de", "#ffffff")
SURFACE_ID = "00000000-0000-4000-8000-000000000042"


def capture(screen, **changes):
    parameters = dict(surface_id=SURFACE_ID, columns=12, rows=2, cursor_column=3, cursor_row=1,
                      cursor_visible=True, alternate_screen=False, revision=42, palette=PALETTE,
                      default_foreground="#e6edff", default_background="#020a33")
    parameters.update(changes)
    return render_grid_from_tmux_capture(screen, **parameters)


def style_for(frame, span):
    return next(style for style in frame["styles"] if style["id"] == span["style_id"])


class MobileRenderGridTests(unittest.TestCase):
    def test_android_existing_decoder_contract_with_color_inverse_acs_and_cursor(self):
        # Shared Android fixture: copy this input's explicit expected DTO values,
        # not a stripped ANSI string or invented replacement terminal identity.
        frame = capture("\x1b[1;38;2;11;228;250mHola \x1b[7m界\x1b[0m\n\x0elqk\x0f")
        self.assertEqual(frame["format"], "cmux.render-grid.v1")
        self.assertEqual(frame["surface_id"], SURFACE_ID)
        self.assertEqual((frame["revision"], frame["state_seq"]), (42, 42))
        self.assertEqual((frame["columns"], frame["rows"]), (12, 2))
        self.assertEqual(frame["cursor"], {"row": 1, "column": 3, "visible": True,
                                         "shape": "block", "blinking": False})
        self.assertEqual(frame["row_spans"], [
            {"row": 0, "column": 0, "style_id": 1, "text": "Hola ", "cell_width": 5},
            {"row": 0, "column": 5, "style_id": 2, "text": "界", "cell_width": 2},
            {"row": 1, "column": 0, "style_id": 0, "text": "┌─┐", "cell_width": 3},
        ])
        self.assertEqual(frame["styles"][1]["foreground"], "#0be4fa")
        self.assertTrue(frame["styles"][1]["bold"])
        self.assertTrue(frame["styles"][2]["inverse"])
        self.assertEqual(frame["active_screen"], "primary")
        self.assertTrue(frame["full"])
        self.assertEqual(frame["cleared_rows"], [])
        self.assertEqual(frame["terminal_background"], "#020a33")
        self.assertEqual(json.loads(json.dumps(frame, ensure_ascii=False)), frame)

    def test_rendition_persists_between_capture_rows_and_reset_restores_defaults(self):
        frame = capture("\x1b[31;44mrojo\nigual\x1b[0mfin")
        first, second, third = frame["row_spans"]
        self.assertEqual(first["style_id"], second["style_id"])
        self.assertEqual(style_for(frame, second)["foreground"], PALETTE[1])
        self.assertEqual(style_for(frame, second)["background"], PALETTE[4])
        self.assertEqual((third["column"], third["style_id"]), (5, 0))

    def test_ansi_bright_palette_uses_injected_desktop_colors(self):
        frame = capture("\x1b[91;104mA")
        style = style_for(frame, frame["row_spans"][0])
        self.assertEqual((style["foreground"], style["background"]), (PALETTE[9], PALETTE[12]))

    def test_indexed_cube_and_gray_colors_or_explicit_256_palette(self):
        frame = capture("\x1b[38;5;196;48;5;244mA")
        style = style_for(frame, frame["row_spans"][0])
        self.assertEqual((style["foreground"], style["background"]), ("#ff0000", "#808080"))
        explicit = ["#abcdef"] * 256
        frame = capture("\x1b[38;5;196mA", palette=explicit)
        self.assertEqual(style_for(frame, frame["row_spans"][0])["foreground"], "#abcdef")
        self.assertEqual(explicit, ["#abcdef"] * 256)

    def test_rgb_semicolon_and_colon_forms_including_default_color_space(self):
        for code in ("38;2;12;34;56", "38:2:12:34:56", "38:2::12:34:56", "38:2:0:12:34:56"):
            with self.subTest(code=code):
                frame = capture(f"\x1b[{code}mA")
                self.assertEqual(style_for(frame, frame["row_spans"][0])["foreground"], "#0c2238")

    def test_default_color_resets_do_not_remove_unrelated_attributes(self):
        frame = capture("\x1b[1;31;44mA\x1b[39;49mB")
        style = style_for(frame, frame["row_spans"][1])
        self.assertTrue(style["bold"])
        self.assertIsNone(style["foreground"])
        self.assertIsNone(style["background"])

    def test_supported_attributes_and_selective_reset(self):
        frame = capture("\x1b[1;2;3;4;5;7;8;9;53mA\x1b[22;23;24;25;27;28;29;55mB")
        style = style_for(frame, frame["row_spans"][0])
        for name in ("bold", "faint", "italic", "underline", "blink", "inverse", "invisible", "strikethrough", "overline"):
            self.assertTrue(style[name], name)
        self.assertEqual(frame["row_spans"][1]["style_id"], 0)

    def test_underline_variants_preserve_boolean_shared_contract(self):
        for code in ("4:1", "4:2", "4:3", "4:4", "4:5", "21"):
            with self.subTest(code=code):
                frame = capture(f"\x1b[{code}mA\x1b[4:00mB")
                self.assertTrue(style_for(frame, frame["row_spans"][0])["underline"])
                self.assertFalse(style_for(frame, frame["row_spans"][1])["underline"])
        frame = capture("\x1b[5:3mA")
        self.assertTrue(style_for(frame, frame["row_spans"][0])["overline"])

    def test_underline_color_metadata_does_not_corrupt_foreground_or_width(self):
        frame = capture("\x1b[4;58;2;1;2;3mA\x1b[58:5:9mB\x1b[59mC")
        self.assertEqual(frame["row_spans"][0]["text"], "ABC")
        self.assertIsNone(style_for(frame, frame["row_spans"][0])["foreground"])

    def test_wide_combining_variation_selector_and_zwj_widths_are_not_len(self):
        for text, width in (("界a", 3), ("e\u0301", 1), ("❤\ufe0f", 2), ("👩\u200d💻X", 3)):
            with self.subTest(text=text):
                frame = capture(text)
                self.assertEqual(frame["row_spans"][0]["text"], text)
                self.assertEqual(frame["row_spans"][0]["cell_width"], width)
        with patch.dict("os.environ", {"UNICODE_VERSION": "4.1.0"}):
            self.assertEqual(capture("👩\u200d💻")["row_spans"][0]["cell_width"], 2)

    def test_acs_switches_translate_glyphs_without_changing_unicode_positions(self):
        frame = capture("\x0elqk\x0fX\x1b(0mqj\x1b(BY")
        self.assertEqual(frame["row_spans"][0]["text"], "┌─┐X└─┘Y")
        self.assertEqual(frame["row_spans"][0]["cell_width"], 8)
        frame = capture("\x0el\x1b[0mq\x0fX")
        self.assertEqual(frame["row_spans"][0]["text"], "┌─X")

    def test_colored_trailing_spaces_and_empty_rows_are_not_trimmed(self):
        frame = capture("\n\x1b[48;5;21m    \x1b[0m\n")
        self.assertEqual(frame["row_spans"][0]["text"], "    ")
        self.assertEqual((frame["row_spans"][0]["row"], frame["row_spans"][0]["cell_width"]), (1, 4))
        self.assertEqual(style_for(frame, frame["row_spans"][0])["background"], "#0000ff")
        self.assertEqual(capture("\n\n")["row_spans"], [])
        self.assertEqual(capture("")["row_spans"], [])

    def test_full_alternate_snapshot_preserves_cursor_visibility_and_revision(self):
        frame = capture("pantalla", alternate_screen=True, cursor_visible=False, revision=2**64 - 1)
        self.assertEqual(frame["active_screen"], "alternate")
        self.assertFalse(frame["cursor"]["visible"])
        self.assertEqual(frame["revision"], 2**64 - 1)
        self.assertEqual(frame["scrollback_rows"], 0)
        self.assertEqual(frame["modes"], [])

    def test_full_history_shares_styles_preserves_blank_rows_and_viewport_coordinates(self):
        frame = capture("\x1b[31;7m界\n\n\x0elqk\x0f\x1b[0mX\n", scrollback_rows=2)
        self.assertEqual(frame["scrollback_rows"], 2)
        self.assertEqual(frame["scrollback_spans"], [
            {"row": 0, "column": 0, "style_id": 1, "text": "界", "cell_width": 2},
        ])
        self.assertEqual(frame["row_spans"], [
            {"row": 0, "column": 0, "style_id": 1, "text": "┌─┐", "cell_width": 3},
            {"row": 0, "column": 3, "style_id": 0, "text": "X", "cell_width": 1},
        ])
        self.assertEqual(len(frame["styles"]), 2)
        self.assertEqual(frame["styles"][1]["foreground"], PALETTE[1])
        self.assertTrue(frame["styles"][1]["inverse"])
        self.assertEqual((frame["rows"], frame["cursor"]["row"], frame["cursor"]["column"]), (2, 1, 3))
        self.assertTrue(frame["full"])
        self.assertEqual(frame["cleared_rows"], [])

    def test_history_is_oldest_first_and_bounded_to_5000_physical_rows(self):
        history = [f"H{number:04d}" for number in range(5000)]
        frame = capture("\n".join(history + ["Visible", ""]), scrollback_rows=5000)
        self.assertEqual(frame["scrollback_rows"], 5000)
        self.assertEqual([span["row"] for span in frame["scrollback_spans"]], list(range(5000)))
        self.assertEqual([span["text"] for span in frame["scrollback_spans"]], history)
        self.assertEqual(frame["row_spans"], [
            {"row": 0, "column": 0, "style_id": 0, "text": "Visible", "cell_width": 7},
        ])
        for count in (-1, 5001, True, 1.5):
            with self.subTest(count=count), self.assertRaises(CaptureRenderError):
                capture("", scrollback_rows=count)

    def test_real_tmux_34_history_padding_keeps_reset_color_and_exact_width(self):
        # Observed bytes from an isolated tmux 3.4 capture-pane -p -e -N.
        # Its allocated blank cells are not part of the red HISTORIA text.
        frame = capture("\x1b[31mHISTORIA-000\x1b[39m        \nVisible\n", columns=80, scrollback_rows=1)
        self.assertEqual(frame["scrollback_spans"], [
            {"row": 0, "column": 0, "style_id": 1, "text": "HISTORIA-000", "cell_width": 12},
            {"row": 0, "column": 12, "style_id": 0, "text": "        ", "cell_width": 8},
        ])
        self.assertEqual(style_for(frame, frame["scrollback_spans"][0])["foreground"], PALETTE[1])
        self.assertIsNone(style_for(frame, frame["scrollback_spans"][1])["foreground"])
        self.assertEqual(frame["row_spans"][0]["text"], "Visible")
        self.assertIsNone(style_for(frame, frame["row_spans"][0])["foreground"])

    def test_alternate_frame_omits_history_without_losing_visible_rendition(self):
        frame = capture("\x1b[31mAnterior\nVisible\x1b[0mX\n", scrollback_rows=1, alternate_screen=True)
        self.assertEqual(frame["active_screen"], "alternate")
        self.assertEqual(frame["scrollback_rows"], 0)
        self.assertEqual(frame["scrollback_spans"], [])
        self.assertEqual([span["text"] for span in frame["row_spans"]], ["Visible", "X"])
        self.assertEqual(style_for(frame, frame["row_spans"][0])["foreground"], PALETTE[1])
        self.assertEqual(frame["row_spans"][1]["style_id"], 0)
        self.assertTrue(all(span["row"] == 0 for span in frame["row_spans"]))

    def test_viewport_itself_exceeding_memory_limits_still_fails_explicitly(self):
        for name, limit in (("MAX_SPANS", 1), ("MAX_STYLES", 1), ("MAX_CAPTURE_BYTES", 5),
                            ("MAX_GRID_BYTES", 64)):
            with self.subTest(name=name), patch(f"uniconnect.mobile_render_grid.{name}", limit):
                with self.assertRaises(CaptureRenderError):
                    capture("\x1b[31mH\nV\x1b[0mX\n", scrollback_rows=1)

    def test_span_budget_drops_oldest_complete_rows_with_logarithmic_retries(self):
        from uniconnect import mobile_render_grid
        history = [f"H{number:04d}" for number in range(5000)]
        with patch("uniconnect.mobile_render_grid.MAX_SPANS", 3), patch(
                "uniconnect.mobile_render_grid._CaptureReader", wraps=mobile_render_grid._CaptureReader) as readers:
            frame = capture("\n".join(history + ["Visible", ""]), scrollback_rows=5000)
        self.assertEqual(frame["scrollback_rows"], 2)
        self.assertEqual([(span["row"], span["text"]) for span in frame["scrollback_spans"]],
                         [(0, "H4998"), (1, "H4999")])
        self.assertEqual(frame["row_spans"][0]["text"], "Visible")
        self.assertEqual((frame["rows"], frame["cursor"]["row"], frame["cursor"]["column"]), (2, 1, 3))
        self.assertLessEqual(readers.call_count, 16)

    def test_style_budget_rehydrates_inherited_rendition_and_reindexes_only_retained_styles(self):
        source = "\x1b[31mAntigua\n\x1b[34mIntermedia\n\x1b[32mReciente\nVisible\n"
        with patch("uniconnect.mobile_render_grid.MAX_STYLES", 2):
            frame = capture(source, scrollback_rows=3)
        self.assertEqual(frame["scrollback_rows"], 1)
        self.assertEqual(frame["scrollback_spans"], [
            {"row": 0, "column": 0, "style_id": 1, "text": "Reciente", "cell_width": 8}])
        self.assertEqual(len(frame["styles"]), 2)
        self.assertEqual(frame["styles"][1]["foreground"], PALETTE[2])
        self.assertEqual(frame["row_spans"][0]["style_id"], 1)
        self.assertEqual(frame["row_spans"][0]["row"], 0)
        self.assertEqual([style["id"] for style in frame["styles"]], [0, 1])

    def test_json_budget_retains_newest_fitting_rows_without_changing_viewport(self):
        history = [f"H{number:04d}" for number in range(10)]
        expected = capture("\n".join(history[-2:] + ["Visible", ""]), scrollback_rows=2)
        byte_limit = len(json.dumps(expected, ensure_ascii=False, separators=(",", ":")).encode())
        with patch("uniconnect.mobile_render_grid.MAX_GRID_BYTES", byte_limit):
            frame = capture("\n".join(history + ["Visible", ""]), scrollback_rows=10)
        self.assertEqual(frame, expected)
        self.assertLessEqual(len(json.dumps(frame, ensure_ascii=False, separators=(",", ":")).encode()), byte_limit)

    def test_json_budget_style_renumbering_keeps_the_maximum_fitting_history(self):
        repeated = "\x1b[38;2;1;1;200m"
        history = ["O" * 1000, repeated + "B"] + [f"\x1b[38;2;{i};20;30mH" for i in range(1, 10)]
        viewport = (repeated + "X\x1b[0mY") * 400

        def render(retained):
            return capture("\n".join(history[len(history) - retained:] + [viewport]),
                           scrollback_rows=retained, columns=1000, rows=1, cursor_row=0, cursor_column=800)

        def encoded_size(frame):
            return len(json.dumps(frame, ensure_ascii=False, separators=(",", ":")).encode())

        def canonical_colors(frame):
            # This fixture varies only foreground RGB: the expected canonical
            # order is independently known, with the default kept at zero.
            ordered = sorted(frame["styles"], key=lambda style: (style["id"] != 0, style["foreground"] or ""))
            identifiers = {style["id"]: index for index, style in enumerate(ordered)}
            return {**frame,
                    "styles": [{**style, "id": index} for index, style in enumerate(ordered)],
                    **{field: [{**span, "style_id": identifiers[span["style_id"]]} for span in frame[field]]
                       for field in ("row_spans", "scrollback_spans")}}

        originals = [render(retained) for retained in range(12)]
        expected = [canonical_colors(frame) for frame in originals]
        # Appearance-order IDs assign the heavily used viewport color 10 at
        # nine rows, but 1 at ten: more history actually takes fewer bytes.
        self.assertGreater(encoded_size(originals[9]), encoded_size(originals[10]))
        self.assertEqual([span["style_id"] for span in originals[9]["row_spans"][:2]], [10, 0])
        sizes = [encoded_size(frame) for frame in expected]
        self.assertEqual(sizes, sorted(sizes))
        for requested, maximum in ((11, 10), (9, 9)):
            with self.subTest(requested=requested):
                limit = sizes[maximum]
                self.assertGreater(encoded_size(originals[requested]), limit)
                self.assertEqual(max(n for n in range(requested + 1) if sizes[n] <= limit), maximum)
                with patch("uniconnect.mobile_render_grid.MAX_GRID_BYTES", limit):
                    actual = render(requested)
                self.assertEqual(actual, expected[maximum])
                self.assertEqual(actual["cursor"], originals[requested]["cursor"])
                self.assertEqual((actual["rows"], actual["columns"]), (1, 1000))
                self.assertEqual(style_for(actual, actual["row_spans"][0])["foreground"], "#0101c8")
                self.assertLessEqual(encoded_size(actual), limit)

    def test_canonical_budget_never_discards_a_valid_original_viewport(self):
        repeated = "\x1b[38;2;200;1;1m"
        viewport = (repeated + "X\x1b[0mY") * 400
        viewport += "".join(f"\x1b[38;2;{i};20;30mH" for i in range(1, 10))
        options = dict(columns=1000, rows=1, cursor_row=0, cursor_column=809)
        expected = capture(viewport, **options)
        limit = len(json.dumps(expected, ensure_ascii=False, separators=(",", ":")).encode())
        self.assertEqual(expected["row_spans"][0]["style_id"], 1)
        # Canonical RGB order moves this frequently used style from ID 1 to 10,
        # enlarging the viewport itself; original IDs still fit without history.
        with patch("uniconnect.mobile_render_grid.MAX_GRID_BYTES", limit):
            actual = capture("O" * 1000 + "\n" + viewport, scrollback_rows=1, **options)
        self.assertEqual(actual, expected)

    def test_history_that_cannot_fit_never_invalidates_a_valid_viewport(self):
        with patch("uniconnect.mobile_render_grid.MAX_SPANS", 1):
            frame = capture("\x1b[31mAntigua\n\x1b[34mReciente\n\x1b[0mVisible\n", scrollback_rows=2)
        self.assertEqual(frame["scrollback_rows"], 0)
        self.assertEqual(frame["scrollback_spans"], [])
        self.assertEqual(frame["row_spans"][0]["text"], "Visible")
        self.assertEqual(frame["row_spans"][0]["style_id"], 0)
        self.assertEqual(len(frame["styles"]), 1)

    def test_alternate_history_does_not_consume_visible_style_or_span_budgets(self):
        with patch("uniconnect.mobile_render_grid.MAX_SPANS", 1), patch("uniconnect.mobile_render_grid.MAX_STYLES", 1):
            frame = capture("\x1b[31mAntigua\n\x1b[34mReciente\n\x1b[0mVisible\n",
                            scrollback_rows=2, alternate_screen=True)
        self.assertEqual(frame["active_screen"], "alternate")
        self.assertEqual(frame["scrollback_rows"], 0)
        self.assertEqual(frame["scrollback_spans"], [])
        self.assertEqual(frame["row_spans"][0]["text"], "Visible")

    def test_hyperlinks_are_bounded_metadata_never_retained_or_opened(self):
        for terminator in ("\x07", "\x1b\\"):
            with self.subTest(terminator=terminator):
                frame = capture(f"A\x1b]8;id=fixture;https://example.invalid/private{terminator}B\x1b]8;;{terminator}C")
                self.assertEqual(frame["row_spans"][0]["text"], "ABC")
                self.assertNotIn("example.invalid", json.dumps(frame))

    def test_unknown_vt_commands_and_custom_tabs_fail_instead_of_stripping(self):
        for screen in ("\x1b[2Jtext", "\x1b[10;10Htext", "\x1b]52;c;clipboard\x07text", "a\tb", "a\rb",
                       "\x1bc", "\x00", "\x08", "\x7f", "\x85", "\x1b[999mtext", "\x1b", "\x1b[31"):
            with self.subTest(screen=repr(screen)), self.assertRaises(CaptureRenderError):
                capture(screen)

    def test_invalid_or_excessive_extended_colors_are_rejected(self):
        for code in ("38;2;1;2", "38;5;256", "48;2;256;1;2", "38:2:1:2:3:4", "4:9", "38;9;1",
                     "38:5:0009", "31m\x1b[H", "38:2::1:2:999"):
            with self.subTest(code=code), self.assertRaises(CaptureRenderError):
                capture(f"\x1b[{code}mA")

    def test_unicode_or_row_overflow_never_returns_a_truncated_frame(self):
        for screen, changes in (("界", {"columns": 1, "cursor_column": 0}), ("a" * 13, {}),
                                ("\n\n\n", {}), ("\u0301", {}), ("\ud800", {})):
            with self.subTest(screen=repr(screen)), self.assertRaises(CaptureRenderError):
                capture(screen, **changes)

    def test_bad_dimensions_cursor_identity_palette_and_revision_are_rejected(self):
        for changes in ({"columns": True}, {"rows": 0}, {"rows": 1001}, {"cursor_row": 2}, {"cursor_column": -1},
                        {"revision": -1}, {"revision": 2**64}, {"cursor_visible": 1}, {"alternate_screen": 0},
                        {"surface_id": ""}, {"surface_id": "\ud800"}, {"palette": []}, {"palette": ["bad"] * 16},
                        {"default_foreground": "red"}, {"default_background": "#00000080"}):
            with self.subTest(changes=changes), self.assertRaises(CaptureRenderError):
                capture("", **changes)

    def test_style_reuse_does_not_grow_the_registry_or_unnecessarily_split_runs(self):
        frame = capture("\x1b[31mA\x1b[31mB\x1b[0mC\x1b[31mD")
        self.assertEqual(len(frame["styles"]), 2)
        self.assertEqual([span["text"] for span in frame["row_spans"]], ["AB", "C", "D"])
        self.assertEqual([span["style_id"] for span in frame["row_spans"]], [1, 0, 1])

    def test_memory_limits_fail_before_sending_partial_frames(self):
        limits = (("MAX_CAPTURE_BYTES", 3, "1234"), ("MAX_STYLES", 1, "\x1b[31mX"),
                  ("MAX_SPANS", 1, "A\x1b[31mB"), ("MAX_GRID_BYTES", 64, "X"),
                  ("MAX_CONTROL_BYTES", 10, "\x1b]8;;https://example.invalid\x07X"))
        for name, value, screen in limits:
            with self.subTest(name=name), patch(f"uniconnect.mobile_render_grid.{name}", value):
                with self.assertRaises(CaptureRenderError):
                    capture(screen)

    def test_missing_or_obsolete_width_library_is_explicit_not_len_fallback(self):
        for library in (None, types.SimpleNamespace(__version__="0.2.5", list_versions=lambda: ("15.1.0",)),
                        types.SimpleNamespace(__version__="0.2.13", list_versions=lambda: ("14.0.0",))):
            with self.subTest(library=library), patch.dict(sys.modules, {"wcwidth": library}):
                self.assertFalse(capture_dependencies_ready())
                with self.assertRaisesRegex(CaptureRenderError, "wcwidth"):
                    capture("hola")

    def test_capability_uses_the_same_dependency_gate_as_capture(self):
        with patch("uniconnect.mobile_render_grid._width_function", return_value=lambda text: 1) as gate:
            self.assertTrue(capture_dependencies_ready())
            gate.assert_called_once_with()
        with patch("uniconnect.mobile_render_grid._width_function", side_effect=CaptureRenderError("fixture")):
            self.assertFalse(capture_dependencies_ready())


if __name__ == "__main__":
    unittest.main()
