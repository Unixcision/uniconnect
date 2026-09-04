import { describe, expect, test } from "bun:test";
import { shortcutCategories } from "../data/cmux-shortcuts";

describe("published shortcut data", () => {
  const shortcuts = shortcutCategories.flatMap((category) => category.shortcuts);

  test("documents Cmd+R as focused SSH reconnect and leaves rename unbound", () => {
    const rename = shortcuts.find((shortcut) => shortcut.id === "renameTab");
    const focusedReconnect = shortcuts.find(
      (shortcut) => shortcut.id === "reconnectFocusedSSHWindow",
    );
    const reconnectAll = shortcuts.find(
      (shortcut) => shortcut.id === "reconnectDroppedWindows",
    );

    expect(rename?.combos).toEqual([]);
    expect(focusedReconnect?.combos).toEqual([["⌘", "R"]]);
    expect(reconnectAll?.combos).toEqual([["⌃", "⌘", "R"]]);
  });
});
