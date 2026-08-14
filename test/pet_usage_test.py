import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))

from pet_usage import ACCENT, GOOD, HOT, ORANGE, YELLOW, BAR_H, BAR_MAX_ROWS, FRAME_COUNT, FRAME_H, FRAME_W, LOOP_MS, PET_H, STATE_ROWS, UsagePet, active_quota_rows, active_usage_rows, animation_delay, asset_path, bar_height_for, clamp_window_position, display_settings, is_working, mix_hex, overlay_geometry, overlay_position, panel_position, pet_dimensions, provider_badge, quota_accounts, quota_bar_color, quota_rows, sprite_row_frames, usage_summary, visible_bar_rows

from PIL import Image


def test_usage_summary_uses_real_request_token_and_model_data():
    model, summary = usage_summary(
        {
            "summary": {"requests": 2, "input_tokens": 1200, "output_tokens": 40},
            "active": {"provider": "codex", "model": "gpt-test", "is_active": True},
        }
    )
    assert model == "gpt-test"
    assert summary == "2 request · 1.240 token"


def test_quota_rows_only_uses_real_quota_data():
    rows = quota_rows(
        {
            "quota_accounts": [
                {
                    "name": "Codex",
                    "quotas": [
                        {"label": "Sesi 5 jam", "remaining_percent": 65, "reset_at": "2026-08-06T10:00:00Z"}
                    ],
                }
            ]
        }
    )
    assert rows == [
        {
            "label": "Sesi 5 jam",
            "account": "Codex",
            "provider": "unknown",
            "remaining": 65.0,
            "reset": "2026-08-06T10:00:00Z",
            "active": False,
            "status": "",
        }
    ]
    assert quota_rows({"quota_accounts": []}) == []


def test_quota_rows_keeps_missing_percentage_unknown():
    rows = quota_rows({
        "quota_accounts": [{"name": "Codex", "quotas": [{"label": "Mingguan"}]}],
    })
    assert rows[0]["remaining"] is None


def test_quota_accounts_groups_rows_under_each_account():
    accounts = quota_accounts({"quota_accounts": [
        {"id": "gemini", "provider": "antigravity", "name": "Gemini", "quotas": [
            {"label": "Flash", "remaining_percent": 73}, {"label": "Pro", "remaining_percent": 52},
        ]},
    ]})
    assert [(account["name"], len(account["rows"])) for account in accounts] == [("Gemini", 2)]


def test_snapshot_refresh_always_recomputes_overlay_geometry():
    import inspect
    source = inspect.getsource(UsagePet._accept_snapshot)
    assert "self._apply_overlay_geometry()" in source
    assert "previous_rows != new_rows" not in source

def test_pet_reasserts_topmost_without_focus_activation():
    import inspect
    source = inspect.getsource(UsagePet._keep_topmost)
    assert "SetWindowPos" in source
    assert "0x0001 | 0x0002 | 0x0010" in source

def test_panel_uses_fixed_footer_scroll_and_resize_contract():
    import inspect
    source = inspect.getsource(UsagePet._render)
    assert "footer = Canvas" in source
    assert "Scrollbar" in source
    assert "resize-grip" in source
    assert "footer.pack(side=\"bottom\"" in source


def test_active_usage_rows_carries_recent_model_name():
    now = datetime.now(timezone.utc).isoformat()
    rows = active_usage_rows({
        "recent": [{"timestamp": now, "connection_id": "ag", "model": "gemini-3.6-flash-medium"}],
        "quota_accounts": [{"id": "ag", "provider": "antigravity", "name": "user", "quotas": [{"remaining_percent": 84}]}],
    })
    assert rows[0]["model"] == "gemini-3.6-flash-medium"
    assert rows[0]["connection_id"] == "ag"


def test_active_quota_rows_only_uses_current_consumption():
    snapshot = {
        "recent": [{"provider": "codex", "model": "gpt-live", "connection_id": "live", "timestamp": "2026-08-06T03:15:10Z"}],
        "quota_accounts": [
            {"id": "spent", "provider": "codex", "name": "Spent", "model": "gpt-live", "quotas": [{"label": "Sesi", "remaining_percent": 0}]},
            {"id": "live", "provider": "codex", "name": "Live", "model": "gpt-live", "quotas": [{"label": "Sesi", "remaining_percent": 25}]},
        ],
    }
    snapshot["recent"][0]["timestamp"] = datetime.now(timezone.utc).isoformat()
    assert [(row["account"], row["label"]) for row in active_quota_rows(snapshot)] == [("Live", "Sesi")]

def test_active_usage_rows_collapses_idle_quota_accounts():
    rows = active_usage_rows({
        "active_usages": [{"provider": "codex", "connection_id": "codex", "model": "gpt", "account": "Codex", "timestamp": datetime.now(timezone.utc).isoformat()}],
        "quota_accounts": [
            {"id": "codex", "provider": "codex", "name": "Codex", "model": "gpt", "quotas": [{"remaining_percent": 19}]},
            {"id": "ag", "provider": "antigravity", "name": "Gemini", "model": "gemini", "active": True, "quotas": [{"label": "Pro", "remaining_percent": 87.9}]},
        ],
    })
    assert [(row["provider"], row["account"], row["remaining"]) for row in rows] == [
        ("codex", "Codex", 19.0),]

def test_active_usage_rows_hides_idle_antigravity_quota():
    rows = active_usage_rows({
        "active_usages": [],
        "quota_accounts": [{
            "id": "ag", "provider": "antigravity", "name": "Gemini", "active": True,
            "quotas": [{"remaining_percent": 88}],
        }],
    })
    assert rows == []

def test_active_usage_rows_collapses_stale_active_signal():
    stale = (datetime.now(timezone.utc) - timedelta(seconds=9)).isoformat()
    rows = active_usage_rows({
        "active_usages": [{"provider": "codex", "connection_id": "codex", "timestamp": stale, "is_active": True}],
        "quota_accounts": [{"id": "codex", "provider": "codex", "quotas": [{"remaining_percent": 50}]}],
    })
    assert rows == []

def test_quota_bar_color_thresholds():
    assert quota_bar_color(None) == ACCENT
    assert quota_bar_color(0) == HOT
    assert quota_bar_color(30) == HOT
    assert quota_bar_color(31) == YELLOW
    assert quota_bar_color(49) == YELLOW
    assert quota_bar_color(50) == ORANGE
    assert quota_bar_color(79) == ORANGE
    assert quota_bar_color(80) == GOOD
    assert quota_bar_color(100) == GOOD


def test_working_animation_selects_working_sprite_state():
    pet = UsagePet.__new__(UsagePet)
    pet.snapshot = {"active_usages": [{"provider": "codex", "is_active": True, "timestamp": datetime.now(timezone.utc).isoformat()}]}
    pet.roaming = False
    pet.direction = 1
    assert pet._animation_state() == "working"

def test_activity_and_sprite_contract_matches_hermes_petdex():
    assert is_working({"active": {"is_active": True}})
    assert not is_working({"active": {"is_active": False}})
    assert FRAME_COUNT == 8
    assert LOOP_MS == 1100
    assert animation_delay() == LOOP_MS // FRAME_COUNT
    assert STATE_ROWS == {"idle": 0, "right": 1, "left": 2, "working": 8}

def test_sprite_loader_skips_transparent_tail():
    sheet = Image.new("RGBA", (FRAME_W * FRAME_COUNT, FRAME_H * 9), (0, 0, 0, 0))
    for column in range(6):
        sheet.putpixel((column * FRAME_W + 1, 8 * FRAME_H + 1), (255, 255, 255, 255))
    frames = sprite_row_frames(sheet, 8)
    assert len(frames) == 6
    assert all(frame.getchannel("A").getbbox() for frame in frames)

def test_burn_color_interpolates_without_binary_flash():
    assert mix_hex("#8fd694", "#ffb703", 0.0) == "#8fd694"
    assert mix_hex("#8fd694", "#ffb703", 0.5) == "#c7c64c"
    assert mix_hex("#8fd694", "#ffb703", 1.0) == "#ffb703"

def test_used_pet_asset_rows_never_return_blank_animation_frames():
    with Image.open(asset_path("maha-v2.webp")) as source:
        sheet = source.convert("RGBA")
    for row in STATE_ROWS.values():
        assert all(frame.getchannel("A").getbbox() for frame in sprite_row_frames(sheet, row))


def test_active_usage_rows_keeps_only_recent_mapped_and_unmapped_accounts():
    snapshot = {
        "recent": [
            {"provider": "codex", "model": "gpt-live", "connection_id": "live", "timestamp": "2026-08-06T03:15:10Z"},
            {"provider": "antigravity", "model": "gemini-live", "connection_id": "gemini", "timestamp": "2026-08-06T03:14:59Z"},
        ],
        "quota_accounts": [
            {"id": "spent", "provider": "codex", "name": "spent", "model": "gpt-live", "active": True, "quotas": [{"remaining_percent": 0}]},
            {"id": "live", "provider": "codex", "name": "live", "model": "gpt-live", "active": True, "quotas": [{"remaining_percent": 52}]},
            {"id": "gemini", "provider": "antigravity", "name": "gemini", "model": "gemini-live", "active": True, "quotas": []},
        ],
    }
    for entry in snapshot["recent"]:
        entry["timestamp"] = datetime.now(timezone.utc).isoformat()
    assert [(row["provider"], row["account"], row["remaining"]) for row in active_usage_rows(snapshot)] == [
        ("codex", "live", 52.0),
        ("antigravity", "gemini", None),
    ]
    assert provider_badge("codex") == "CODEX"
    assert provider_badge("antigravity") == "AG"


def test_popup_dispatcher_clicks_controls_and_drags_elsewhere():
    class Panel:
        def __init__(self):
            self.x, self.y = 10, 20

        def winfo_x(self):
            return self.x

        def winfo_y(self):
            return self.y

        def geometry(self, value):
            _, x, y = value.split("+")
            self.x, self.y = int(x), int(y)

    class Event:
        def __init__(self, x, y, x_root, y_root):
            self.x, self.y, self.x_root, self.y_root = x, y, x_root, y_root

    pet = UsagePet.__new__(UsagePet)
    clicked = []
    pet.panel = Panel()
    pet._panel_actions = [(1, 1, 80, 31, lambda: clicked.append(True))]
    pet._panel_drag_start = None
    pet._panel_click_action = None
    pet._panel_drag_begin(Event(20, 20, 100, 100))
    pet._panel_drag_end(Event(20, 20, 100, 100))
    assert clicked == [True]
    pet._panel_drag_begin(Event(120, 80, 100, 100))
    pet._panel_drag_move(Event(120, 80, 110, 106))
    pet._panel_drag_end(Event(120, 80, 110, 106))
    assert (pet.panel.x, pet.panel.y) == (20, 26)


def test_display_settings_clamp_size_and_choose_scaling():
    assert display_settings({}) == (1.0, "sharp", True)
    assert display_settings({"pet_scale": 9, "pet_filter": "smooth", "burn_effect": False}) == (2.0, "smooth", False)
    assert pet_dimensions(0.5) == (67, 72)


def test_overlay_geometry_reserves_clickable_bar_above_pet():
    assert overlay_geometry(True) == (PET_H + BAR_H, BAR_H)
    assert overlay_geometry(False) == (PET_H, 0)
    assert bar_height_for(2) > BAR_H


def test_overlay_position_preserves_pet_bottom_and_clamps_screen():
    bounds = (0, 0, 1920, 1080)
    x, y = overlay_position(1680, 820, 0, 74, PET_H, 220, PET_H + 74, bounds)
    assert (x, y) == (1680, 746)
    assert y + 74 + PET_H == 965
    assert clamp_window_position(1900, 1000, 220, 200, bounds) == (1700, 880)


def test_panel_position_avoids_full_pet_overlay():
    bounds = (0, 0, 1920, 1080)
    panel_x, panel_y = panel_position(1680, 820, 220, 219, 560, 380, bounds)
    assert panel_x == 1340
    assert panel_y == 428
    assert panel_y + 380 <= 820 - 12


def test_visible_bar_rows_caps_overlay_height():
    snapshot = {
        "active_usages": [
            {
                "provider": "codex",
                "model": f"gpt-{index}",
                "account": f"account-{index}",
                "connection_id": f"connection-{index}",
                "timestamp": datetime.now(timezone.utc).isoformat(),
            }
            for index in range(BAR_MAX_ROWS + 1)
        ],
    }
    rows, overflow = visible_bar_rows(snapshot)
    assert len(rows) == BAR_MAX_ROWS
    assert overflow == 1
