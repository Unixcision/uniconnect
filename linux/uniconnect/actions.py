"""Shared action catalogue for menus, shortcuts, palette and context menus."""

from dataclasses import dataclass


@dataclass(frozen=True)
class Action:
    name: str
    label: str
    shortcut: str = ""


ACTIONS = (
    Action("new_workspace", "New workspace", "<Primary><Shift>n"),
    Action("new_window", "New window", "<Primary><Shift>t"),
    Action("close_window", "Close window", "<Primary><Shift>w"),
    Action("close_workspace", "Close workspace", "<Primary><Alt>w"),
    Action("reopen", "Reopen closed", "<Primary><Alt>t"),
    Action("reopen_last", "Reopen last closed", "<Primary><Shift><Alt>t"),
    Action("close_other_windows", "Close other windows in pane"),
    Action("close_left_windows", "Close windows to the left"),
    Action("close_right_windows", "Close windows to the right"),
    Action("save", "Persist now", "<Primary><Shift>s"),
    Action("import_config", "Import configuration"),
    Action("export_config", "Export configuration"),
    Action("restore_backup", "Restore backup"),
    Action("settings", "Settings", "<Primary>comma"),
    Action("lock", "Lock", "<Primary><Shift>l"),
    Action("quit", "Quit", "<Primary><Shift>q"),
    Action("copy", "Copy", "<Primary><Shift>c"),
    Action("paste", "Paste", "<Primary><Shift>v"),
    Action("find", "Find", "<Primary><Shift>f"),
    Action("find_next", "Find next", "<Primary><Shift>g"),
    Action("find_previous", "Find previous", "<Primary><Alt>g"),
    Action("hide_find", "Hide search"),
    Action("find_selection", "Use selection for search"),
    Action("send_ctrl_f", "Send Ctrl-F to terminal"),
    Action("reconnect", "Reconnect", "<Primary><Shift>r"),
    Action("reconnect_all", "Reconnect all SSH", "<Primary><Alt>r"),
    Action("rename_workspace", "Rename workspace"),
    Action("rename_window", "Rename window"),
    Action("reset_window_name", "Reset window name"),
    Action("pin_workspace", "Pin workspace"),
    Action("pin_window", "Pin window"),
    Action("workspace_previous", "Previous workspace", "<Primary><Alt>bracketleft"),
    Action("workspace_next", "Next workspace", "<Primary><Alt>bracketright"),
    Action("window_previous", "Previous window", "<Primary><Shift>bracketleft"),
    Action("window_next", "Next window", "<Primary><Shift>bracketright"),
    Action("workspace_up", "Move workspace up"),
    Action("workspace_down", "Move workspace down"),
    Action("workspace_first", "Move workspace to beginning"),
    Action("edit_ssh", "Edit SSH connection"),
    Action("split_right", "Split right", "<Primary><Shift>d"),
    Action("split_down", "Split down", "<Primary><Alt>d"),
    Action("equalize_panes", "Equalize panes"),
    Action("maximize_pane", "Maximize pane", "<Primary><Shift>Return"),
    Action("focus_left", "Focus pane left", "<Primary><Alt>Left"),
    Action("focus_right", "Focus pane right", "<Primary><Alt>Right"),
    Action("focus_up", "Focus pane above", "<Primary><Alt>Up"),
    Action("focus_down", "Focus pane below", "<Primary><Alt>Down"),
    Action("move_window_left", "Move window to previous pane"),
    Action("move_window_right", "Move window to next pane"),
    Action("sidebar", "Toggle sidebar", "<Primary><Shift>b"),
    Action("palette", "Command palette", "<Primary><Shift>p"),
    Action("upload", "Upload file"),
    Action("notifications", "Notifications", "<Primary><Shift>i"),
    Action("notifications_latest_unread", "Ir a la última no leída", "<Primary><Shift>u"),
    Action("notifications_mark_all_read", "Marcar todo como leído"),
    Action("notifications_toggle_workspace", "Marcar caja como no leída", "<Primary><Alt>u"),
    Action("notifications_toggle_window", "Marcar ventana como no leída"),
    Action("notifications_dismiss_all", "Descartar todas las notificaciones"),
    Action("font_larger", "Font larger", "<Primary>plus"),
    Action("font_smaller", "Font smaller", "<Primary>minus"),
    Action("font_reset", "Font reset", "<Primary>0"),
    Action("fullscreen", "Fullscreen", "F11"),
    Action("kill_tmux", "Terminate remote tmux session"),
    Action("help", "Help", "F1"),
    Action("about", "About UniConnect"),
    Action("help_shortcuts", "Menus and keyboard shortcuts"),
    Action("help_settings", "Keyboard shortcut settings"),
    Action("report_issue", "Report an issue"),
) + tuple(Action(f"workspace_{index}", f"Workspace {index}", f"<Primary><Alt>{index}")
          for index in range(1, 10)) + tuple(
    Action(f"window_{index}", f"Window {index}", f"<Alt>{index}") for index in range(1, 10))
