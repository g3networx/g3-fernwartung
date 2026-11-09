"""Reject releases whose Windows tray still carries a different product icon."""
import struct
from pathlib import Path

root = Path(__file__).resolve().parents[1]
window = (root / 'flutter/windows/runner/resources/app_icon.ico').read_bytes()
tray = (root / 'res/tray-icon.ico').read_bytes()
assert tray == window, 'Tray and taskbar must contain the same approved icon'
reserved, kind, count = struct.unpack_from('<HHH', window)
assert reserved == 0 and kind == 1 and count > 0
sizes = set()
for i in range(count):
    width, height, _, _, _, _, length, offset = struct.unpack_from('<BBBBHHII', window, 6 + i * 16)
    sizes.add((width or 256, height or 256))
    assert length > 0 and offset + length <= len(window)
assert {(16, 16), (20, 20), (24, 24), (32, 32), (48, 48), (256, 256)} <= sizes
print('Tray/taskbar icon resources and Windows size frames verified')
