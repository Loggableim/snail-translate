"""Drive the Snail desktop window: click, type, focus.

Windows blocks SetForegroundWindow for background processes, so focus is
forced through AttachThreadInput — without it every click lands on whatever
window happens to be in front and the app never reacts.
"""
import ctypes
import sys
import time
from ctypes import wintypes

user32 = ctypes.windll.user32


def find_window(title="snail"):
    found = []

    def cb(hwnd, _lparam):
        length = user32.GetWindowTextLengthW(hwnd)
        if length:
            buf = ctypes.create_unicode_buffer(length + 1)
            user32.GetWindowTextW(hwnd, buf, length + 1)
            if buf.value.strip().lower() == title:
                found.append(hwnd)
        return True

    user32.EnumWindows(
        ctypes.WINFUNCTYPE(ctypes.c_bool, wintypes.HWND, wintypes.LPARAM)(cb), 0
    )
    return found[0] if found else None


def focus(hwnd):
    fg = user32.GetForegroundWindow()
    tid_fg = user32.GetWindowThreadProcessId(fg, None)
    tid_me = ctypes.windll.kernel32.GetCurrentThreadId()
    user32.AttachThreadInput(tid_me, tid_fg, True)
    user32.ShowWindow(hwnd, 9)
    user32.SetForegroundWindow(hwnd)
    user32.BringWindowToTop(hwnd)
    user32.AttachThreadInput(tid_me, tid_fg, False)
    time.sleep(0.6)


def client_origin(hwnd):
    pt = wintypes.POINT(0, 0)
    user32.ClientToScreen(hwnd, ctypes.byref(pt))
    return pt.x, pt.y


def click(hwnd, x, y):
    focus(hwnd)
    ox, oy = client_origin(hwnd)
    user32.SetCursorPos(ox + x, oy + y)
    time.sleep(0.35)
    user32.mouse_event(0x0002, 0, 0, 0, 0)
    time.sleep(0.1)
    user32.mouse_event(0x0004, 0, 0, 0, 0)
    time.sleep(0.4)
    print(f"clicked client({x},{y})")


def type_text(hwnd, text):
    focus(hwnd)
    for ch in text:
        vk = user32.VkKeyScanW(ord(ch))
        if vk == -1:
            continue
        shift = (vk >> 8) & 1
        code = vk & 0xFF
        if shift:
            user32.keybd_event(0x10, 0, 0, 0)
        user32.keybd_event(code, 0, 0, 0)
        time.sleep(0.02)
        user32.keybd_event(code, 0, 2, 0)
        time.sleep(0.02)
        if shift:
            user32.keybd_event(0x10, 0, 2, 0)
    print(f"typed: {text}")


def press(hwnd, vk):
    focus(hwnd)
    user32.keybd_event(vk, 0, 0, 0)
    time.sleep(0.05)
    user32.keybd_event(vk, 0, 2, 0)
    print(f"pressed vk={vk}")


if __name__ == "__main__":
    hwnd = find_window()
    if not hwnd:
        print("no snail window")
        sys.exit(1)
    action = sys.argv[1]
    if action == "click":
        click(hwnd, int(sys.argv[2]), int(sys.argv[3]))
    elif action == "type":
        type_text(hwnd, sys.argv[2])
    elif action == "enter":
        press(hwnd, 0x0D)
    elif action == "info":
        rect = wintypes.RECT()
        user32.GetWindowRect(hwnd, ctypes.byref(rect))
        print(f"window {rect.left},{rect.top} {rect.right},{rect.bottom}")
        print(f"client origin {client_origin(hwnd)}")
