# share-grant.py — runs ON THE LAPTOP (copy it there; needs
# HYPRLAND_INSTANCE_SIGNATURE in env). Waits for the xdg portal share
# picker (class hyprland-share-picker) that a RustDesk Wayland session
# raises, then grants it: Remember (0.03w, 0.84h) -> monitor row
# (0.50w, 0.32h) -> Share (0.935w, 0.93h), using ydotool with a
# hyprctl-cursorpos feedback loop (~2.186x fast-move scaling). This is
# the NO-DISMISS variant: the original /tmp/rd-portal-click.py first
# cancelled any existing picker as "stale", which kills the fresh
# picker of the session you are trying to grant. Fractions are of the
# picker's live window geometry ([1080,720] 720x480 on amd-6).
import json, subprocess, time, sys

ENV = dict(__import__('os').environ)

def sh(*args):
    return subprocess.run(args, capture_output=True, text=True, env=ENV).stdout

def clients():
    return json.loads(sh('hyprctl', 'clients', '-j') or '[]')

def picker():
    for c in clients():
        if c.get('class') == 'hyprland-share-picker':
            return c
    return None

def cursor():
    out = sh('hyprctl', 'cursorpos').strip().replace(' ', '')
    x, y = out.split(',')
    return int(x), int(y)

def move_to(tx, ty):
    for _ in range(16):
        cx, cy = cursor()
        dx, dy = tx - cx, ty - cy
        if abs(dx) <= 4 and abs(dy) <= 4:
            break
        if abs(dx) > 60 or abs(dy) > 60:
            rx, ry = int(dx * 1000 / 2186), int(dy * 1000 / 2186)
        else:
            rx = dx // 2 if dx % 2 == 0 else (1 if dx > 0 else -1) * (abs(dx) // 2 if abs(dx) > 1 else 1)
            ry = dy // 2 if dy % 2 == 0 else (1 if dy > 0 else -1) * (abs(dy) // 2 if abs(dy) > 1 else 1)
            if rx == 0 and dx != 0: rx = 1 if dx > 0 else -1
            if ry == 0 and dy != 0: ry = 1 if dy > 0 else -1
        subprocess.run(['ydotool', 'mousemove', '--', str(rx), str(ry)], env=ENV)
        time.sleep(0.7)
    return cursor()

def click(tx, ty):
    at = move_to(tx, ty)
    subprocess.run(['ydotool', 'click', '-D', '120', '0xC0'], env=ENV)
    print(f'clicked target ({tx},{ty}) from {at}', flush=True)
    time.sleep(1.2)

# 2. Wait for the fresh picker (the client connects meanwhile).
deadline = time.time() + 90
p = None
while time.time() < deadline:
    p = picker()
    if p:
        break
    time.sleep(1.5)
if not p:
    print('NO PICKER APPEARED', flush=True)
    sys.exit(2)
print('picker up:', p['at'], p['size'], flush=True)
x, y = p['at']; w, h = p['size']
# 3. Remember -> entry -> Share, geometry from the live window.
click(x + int(0.03 * w), y + int(0.84 * h))   # Remember checkbox
click(x + int(0.50 * w), y + int(0.32 * h))   # eDP-1 entry row
click(x + int(0.935 * w), y + int(0.93 * h))  # Share
time.sleep(2)
print('picker after share:', picker() is not None, flush=True)
