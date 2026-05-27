import logging
logging.getLogger('werkzeug').setLevel(logging.ERROR)

from flask import Flask, render_template, jsonify, request
import RPi.GPIO as GPIO
import subprocess, os, json, threading, time

app = Flask(__name__)

# ═══════════════════════════════════════════════════════════════════════════════
# GPIO — схема пинов по ТЗ
# Насосы 1–4 : GPIO 4, 5, 6, 13  (дискретные)
# Насос 5    : GPIO 19            (аппаратный PWM1)
# Насос 6    : GPIO 17            (дискретный)
# Серво огня : GPIO 18            (аппаратный PWM0)
# Серво 5    : GPIO 16
# Серво 6    : GPIO 21
# LED        : GPIO 26
# WS2812B    : УДАЛЕНА
# ═══════════════════════════════════════════════════════════════════════════════
GPIO.setmode(GPIO.BCM)
GPIO.setwarnings(False)

PUMP_PINS      = {1: 4, 2: 5, 3: 6, 4: 13, 5: 19, 6: 17}
LED_PIN        = 26
SERVO_FIRE_PIN = 18
SERVO_5_PIN    = 16
SERVO_6_PIN    = 21

for pin in PUMP_PINS.values():
    GPIO.setup(pin, GPIO.OUT, initial=GPIO.LOW)
GPIO.setup(LED_PIN,        GPIO.OUT, initial=GPIO.LOW)
GPIO.setup(SERVO_FIRE_PIN, GPIO.OUT, initial=GPIO.LOW)
GPIO.setup(SERVO_5_PIN,    GPIO.OUT, initial=GPIO.LOW)
GPIO.setup(SERVO_6_PIN,    GPIO.OUT, initial=GPIO.LOW)

led_pwm        = GPIO.PWM(LED_PIN,        1000); led_pwm.start(0)
servo_fire_pwm = GPIO.PWM(SERVO_FIRE_PIN,   50); servo_fire_pwm.start(0)
servo5_pwm     = GPIO.PWM(SERVO_5_PIN,      50); servo5_pwm.start(0)
servo6_pwm     = GPIO.PWM(SERVO_6_PIN,      50); servo6_pwm.start(0)

pump_pwm = {}
for num, pin in PUMP_PINS.items():
    p = GPIO.PWM(pin, 1000)
    p.start(0)
    pump_pwm[num] = p

# ═══════════════════════════════════════════════════════════════════════════════
# MASTER RATIO  п.2.4
# ═══════════════════════════════════════════════════════════════════════════════
master_ratio = 1.0

def pump_duty(raw_value):
    return max(0.0, min(100.0, raw_value * master_ratio))

# ═══════════════════════════════════════════════════════════════════════════════
# WATCHDOG  (show_running объявлен здесь — до старта потока)
# ═══════════════════════════════════════════════════════════════════════════════
WATCHDOG_TIMEOUT = 5.0
_last_ping       = time.time()
_watchdog_active = False

show_running  = False
show_thread   = None
music_process = None

def _watchdog_loop():
    while True:
        time.sleep(1.0)
        if not _watchdog_active or show_running:
            continue
        if time.time() - _last_ping > WATCHDOG_TIMEOUT:
            print('Watchdog: нет пинга >5с → all_off()')
            all_off()

threading.Thread(target=_watchdog_loop, daemon=True).start()

@app.route('/api/ping')
def api_ping():
    global _last_ping, _watchdog_active
    _last_ping       = time.time()
    _watchdog_active = True
    return jsonify(ok=True)

@app.route('/api/ping/stop')
def api_ping_stop():
    global _watchdog_active
    _watchdog_active = False
    return jsonify(ok=True)

# ═══════════════════════════════════════════════════════════════════════════════
# DIRS
# ═══════════════════════════════════════════════════════════════════════════════
MUSIC_DIR     = '/home/pi/fountain/music'
SCENARIOS_DIR = '/home/pi/fountain/scenarios'
os.makedirs(MUSIC_DIR,     exist_ok=True)
os.makedirs(SCENARIOS_DIR, exist_ok=True)

# ═══════════════════════════════════════════════════════════════════════════════
# SERVO HELPERS
# ═══════════════════════════════════════════════════════════════════════════════
def servo_duty(v):
    """Обычные серво: 2.5–12.5%."""
    return 2.5 + (max(0, min(100, v)) / 100.0) * 10.0

def servo_duty_fire(v):
    """Серво огня: +1.1 смещение (~+20°), потолок 12.5%.  п.2.3"""
    return min(2.5 + (max(0, min(100, v)) / 100.0) * 10.0 + 1.1, 12.5)

# ── Servo dispatcher ──────────────────────────────────────────────────────────
# п.3.2 ТЗ: цикл 20мс (50Гц), команды применяются мгновенно и непрерывно.
# time.sleep ВНУТРИ потока запрещён.
# ChangeDutyCycle(0) вызывается только если команд не было >0.5с (Smart Hold).
SERVO_PIN_WHITELIST  = {SERVO_FIRE_PIN, SERVO_5_PIN, SERVO_6_PIN}
SERVO_SMART_HOLD_SEC = 0.5   # секунд без команд → снять ШИМ

_servo_cmds  = {}   # pin_id → {'pwm', 'value', 'pin', 'ts'}
_servo_hold  = {}   # pin_id → True/False  (ШИМ сейчас активен?)
_servo_lock  = threading.Lock()
_servo_event = threading.Event()

def _servo_worker():
    """
    Цикл 20мс. Алгоритм:
    1. Если есть новая команда — применяем ChangeDutyCycle(duty) немедленно.
    2. Пока команды приходят — ШИМ держим активным (серво следует за пальцем).
    3. Если команд не было >SERVO_SMART_HOLD_SEC — снимаем ШИМ (ChangeDutyCycle(0)).
    """
    while True:
        _servo_event.wait(timeout=0.02)   # максимум 20мс между итерациями
        _servo_event.clear()
        now = time.time()

        with _servo_lock:
            cmds_snap = dict(_servo_cmds)
            hold_snap = dict(_servo_hold)

        for pid, cmd in cmds_snap.items():
            pin = cmd['pin']
            if pin not in SERVO_PIN_WHITELIST:
                continue
            try:
                duty = servo_duty_fire(cmd['value']) if pin == SERVO_FIRE_PIN \
                       else servo_duty(cmd['value'])
                cmd['pwm'].ChangeDutyCycle(duty)
                with _servo_lock:
                    _servo_hold[pid] = True
            except Exception as e:
                print(f'servo_worker apply error pin {pin}: {e}')

        # Smart Hold: проверяем все активные серво у которых давно не было команд
        with _servo_lock:
            active_holds = {pid: ts for pid, ts in
                            [(p, _servo_cmds[p]['ts']) for p in _servo_hold
                             if _servo_hold.get(p) and p in _servo_cmds]}
        for pid, last_ts in active_holds.items():
            if now - last_ts > SERVO_SMART_HOLD_SEC:
                with _servo_lock:
                    cmd = _servo_cmds.get(pid)
                    if cmd and now - cmd['ts'] > SERVO_SMART_HOLD_SEC:
                        try:
                            cmd['pwm'].ChangeDutyCycle(0)
                        except Exception:
                            pass
                        _servo_hold[pid] = False
                        del _servo_cmds[pid]

def apply_servo_async(pwm, value, pin):
    """Кладёт команду в очередь. Поток применит на следующей итерации (~20мс)."""
    pid = id(pwm)
    with _servo_lock:
        _servo_cmds[pid] = {'pwm': pwm, 'value': value, 'pin': pin, 'ts': time.time()}
    _servo_event.set()

# ═══════════════════════════════════════════════════════════════════════════════
# PROCESS HELPERS
# ═══════════════════════════════════════════════════════════════════════════════
def _kill_proc(proc, timeout=2):
    if proc is None or proc.poll() is not None:
        return
    proc.terminate()
    try:
        proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        try:
            proc.wait(timeout=1)
        except subprocess.TimeoutExpired:
            print('_kill_proc: не завершился даже после kill')

def stop_music():
    global music_process
    if music_process is not None:
        _kill_proc(music_process)
        music_process = None

def all_off():
    for p in pump_pwm.values():
        p.ChangeDutyCycle(0)
    led_pwm.ChangeDutyCycle(0)
    servo_fire_pwm.ChangeDutyCycle(7.5)
    time.sleep(0.3)
    servo_fire_pwm.ChangeDutyCycle(0)

def apply_state(state):
    try:
        for n in range(1, 7):
            key = 'p' + str(n)
            if key in state and n in pump_pwm:
                pump_pwm[n].ChangeDutyCycle(pump_duty(state[key]))
        if 'led' in state:
            led_pwm.ChangeDutyCycle(max(0, min(100, state['led'])))
        if 'fire' in state:
            if state['fire']:
                servo_fire_pwm.ChangeDutyCycle(servo_duty_fire(100))
            else:
                servo_fire_pwm.ChangeDutyCycle(7.5)
                threading.Timer(0.15, lambda: servo_fire_pwm.ChangeDutyCycle(0)).start()
        if 's5' in state:
            apply_servo_async(servo5_pwm, state['s5'], SERVO_5_PIN)
        if 's6' in state:
            apply_servo_async(servo6_pwm, state['s6'], SERVO_6_PIN)
    except Exception as e:
        print(f'apply_state error: {e}')

# ═══════════════════════════════════════════════════════════════════════════════
# ROUTES — INDEX
# ═══════════════════════════════════════════════════════════════════════════════
@app.route('/')
def index():
    return render_template('index.html')

# ═══════════════════════════════════════════════════════════════════════════════
# ROUTES — TRACKS
# ═══════════════════════════════════════════════════════════════════════════════
def get_track_duration(filename):
    """ffprobe → mutagen → mpg123. Fallback 180."""
    filepath = os.path.join(MUSIC_DIR, filename)
    if not os.path.exists(filepath):
        return 180.0
    try:
        r = subprocess.run(
            ['ffprobe', '-v', 'error', '-show_entries', 'format=duration',
             '-of', 'default=noprint_wrappers=1:nokey=1', filepath],
            capture_output=True, text=True, timeout=10)
        raw = r.stdout.strip()
        if raw:
            val = float(raw)
            if val > 0:
                return round(val, 2)
    except Exception:
        pass
    try:
        from mutagen.mp3 import MP3
        return round(MP3(filepath).info.length, 2)
    except Exception:
        pass
    try:
        r = subprocess.run(['mpg123', '--length', filepath],
                           capture_output=True, text=True, timeout=20)
        for line in (r.stdout + r.stderr).splitlines():
            if 'samples:' in line and 'samplerate:' in line:
                parts = line.split()
                s  = int(parts[parts.index('samples:')    + 1])
                sr = int(parts[parts.index('samplerate:') + 1])
                if sr > 0:
                    return round(s / sr, 2)
    except Exception:
        pass
    return 180.0

@app.route('/api/tracks')
def get_tracks():
    tracks = {'greeting': None, 'farewell': None, 'songs': []}
    for f in sorted(os.listdir(MUSIC_DIR)):
        if not f.endswith('.mp3'):
            continue
        has_sc = os.path.exists(
            os.path.join(SCENARIOS_DIR, f.replace('.mp3', '.json')))
        item = {'name': f, 'has_scenario': has_sc, 'duration': get_track_duration(f)}
        if   f.startswith('greeting_'): tracks['greeting'] = item
        elif f.startswith('farewell_'): tracks['farewell'] = item
        else:                            tracks['songs'].append(item)
    return jsonify(tracks)

@app.route('/api/upload/<track_type>', methods=['POST'])
def upload(track_type):
    if 'file' not in request.files:
        return jsonify(success=False, error='Нет файла')
    file = request.files['file']
    if not file.filename.endswith('.mp3'):
        return jsonify(success=False, error='Только MP3')
    if track_type == 'song':
        songs = [f for f in os.listdir(MUSIC_DIR)
                 if f.endswith('.mp3')
                 and not f.startswith('greeting_')
                 and not f.startswith('farewell_')]
        if len(songs) >= 15:
            return jsonify(success=False, error='Максимум 15 песен')
        filename = file.filename
    elif track_type in ('greeting', 'farewell'):
        for f in os.listdir(MUSIC_DIR):
            if f.startswith(track_type + '_'):
                os.remove(os.path.join(MUSIC_DIR, f))
                sc = os.path.join(SCENARIOS_DIR, f.replace('.mp3', '.json'))
                if os.path.exists(sc): os.remove(sc)
        filename = track_type + '_' + file.filename
    else:
        return jsonify(success=False, error='Неверный тип')
    file.save(os.path.join(MUSIC_DIR, filename))
    return jsonify(success=True, filename=filename)

@app.route('/api/delete/<filename>', methods=['DELETE'])
def delete_track(filename):
    for d, fn in [(MUSIC_DIR, filename),
                  (SCENARIOS_DIR, filename.replace('.mp3', '.json'))]:
        p = os.path.join(d, fn)
        if os.path.exists(p): os.remove(p)
    return jsonify(success=True)

@app.route('/api/delete_scenario/<filename>', methods=['DELETE'])
def delete_scenario(filename):
    p = os.path.join(SCENARIOS_DIR, filename.replace('.mp3', '.json'))
    if os.path.exists(p): os.remove(p)
    return jsonify(success=True)

@app.route('/api/duration/<filename>')
def get_duration(filename):
    return jsonify(duration=get_track_duration(filename))

@app.route('/api/play/<filename>')
def play_track(filename):
    global music_process
    filepath = os.path.join(MUSIC_DIR, filename)
    if not os.path.exists(filepath):
        return jsonify(success=False, error='Файл не найден')
    stop_music()
    music_process = subprocess.Popen(
        ['mpg123', '-q', '--buffer', '1024', filepath],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return jsonify(success=True)

@app.route('/api/stop_music')
def stop_music_route():
    stop_music()
    return jsonify(success=True)

@app.route('/api/save_scenario', methods=['POST'])
def save_scenario():
    data     = request.json
    filename = data.get('filename', '').replace('.mp3', '.json')
    scenario = data.get('scenario', [])
    with open(os.path.join(SCENARIOS_DIR, filename), 'w', encoding='utf-8') as f:
        json.dump(scenario, f, ensure_ascii=False)
    return jsonify(success=True)

@app.route('/api/scenario/<filename>')
def get_scenario(filename):
    p = os.path.join(SCENARIOS_DIR, filename.replace('.mp3', '.json'))
    if os.path.exists(p):
        with open(p, encoding='utf-8') as f:
            return jsonify(json.load(f))
    return jsonify([])

@app.route('/api/all_off')
def all_off_route():
    all_off()
    return jsonify(success=True)

# ═══════════════════════════════════════════════════════════════════════════════
# MASTER RATIO endpoint  п.2.4
# ═══════════════════════════════════════════════════════════════════════════════
@app.route('/api/set_master/<int:value>')
def set_master(value):
    global master_ratio
    master_ratio = max(0.0, min(100, value)) / 100.0
    return jsonify(success=True, master_ratio=master_ratio)

# ═══════════════════════════════════════════════════════════════════════════════
# RECORDING  п.2.5
# ═══════════════════════════════════════════════════════════════════════════════
@app.route('/api/record/start', methods=['POST'])
def record_start():
    global music_process
    data       = request.json or {}
    filename   = data.get('filename', '')
    offset_sec = float(data.get('offset_sec', 0))
    is_slow    = bool(data.get('slow', False))
    filepath   = os.path.join(MUSIC_DIR, ('_slow_' if is_slow else '') + filename)
    if not os.path.exists(filepath):
        return jsonify(success=False, error=f'Файл не найден: {filepath}')
    stop_music()
    frames = int(offset_sec / 0.02611)
    music_process = subprocess.Popen(
        ['mpg123', '-q', '--buffer', '1024', '-k', str(frames), filepath],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return jsonify(success=True)

@app.route('/api/record/stop')
def record_stop():
    stop_music()
    return jsonify(success=True)

# ═══════════════════════════════════════════════════════════════════════════════
# DIRECT CONTROL
# ═══════════════════════════════════════════════════════════════════════════════
@app.route('/api/set_pump/<int:num>/<int:value>')
def set_pump(num, value):
    if num in pump_pwm:
        pump_pwm[num].ChangeDutyCycle(pump_duty(value))
    return jsonify(success=True)

@app.route('/api/set_led/<int:value>')
def set_led(value):
    led_pwm.ChangeDutyCycle(max(0, min(100, value)))
    return jsonify(success=True)

@app.route('/api/set_fire/<int:on>')
def set_fire(on):
    if on:
        servo_fire_pwm.ChangeDutyCycle(servo_duty_fire(100))
    else:
        servo_fire_pwm.ChangeDutyCycle(7.5)
        # Не используем time.sleep в обработчике запроса — отключим через диспетчер
        threading.Timer(0.15, lambda: servo_fire_pwm.ChangeDutyCycle(0)).start()
    return jsonify(success=True)

@app.route('/api/set_servo/<int:num>/<int:value>')
def set_servo_route(num, value):
    if num == 5:
        apply_servo_async(servo5_pwm, value, SERVO_5_PIN)
    elif num == 6:
        apply_servo_async(servo6_pwm, value, SERVO_6_PIN)
    return jsonify(success=True)

# ═══════════════════════════════════════════════════════════════════════════════
# SLOW VERSIONS
# ═══════════════════════════════════════════════════════════════════════════════
@app.route('/api/make_slow/<filename>/<float:speed>')
def make_slow(filename, speed):
    src = os.path.join(MUSIC_DIR, filename)
    dst = os.path.join(MUSIC_DIR, '_slow_' + filename)
    if not os.path.exists(src):
        return jsonify(success=False, error='Файл не найден')
    if os.path.exists(dst):
        os.remove(dst)
    try:
        af = f'atempo={speed}' if speed >= 0.5 else f'atempo=0.5,atempo={speed/0.5}'
        result = subprocess.run(
            ['ffmpeg', '-y', '-i', src, '-filter:a', af, dst],
            capture_output=True, timeout=120)
        if result.returncode != 0:
            err = result.stderr.decode('utf-8', errors='replace')[-300:]
            return jsonify(success=False, error=f'ffmpeg: {err}')
    except Exception as e:
        return jsonify(success=False, error=str(e))
    return jsonify(success=True)

@app.route('/api/delete_slow/<filename>')
def delete_slow(filename):
    dst = os.path.join(MUSIC_DIR, '_slow_' + filename)
    if os.path.exists(dst):
        os.remove(dst)
    return jsonify(success=True)

@app.route('/api/play_from/<filename>/<float:offset_sec>')
def play_from(filename, offset_sec):
    global music_process
    filepath = os.path.join(MUSIC_DIR, filename)
    if not os.path.exists(filepath):
        return jsonify(success=False, error='Файл не найден')
    stop_music()
    frames = int(offset_sec / 0.02611)
    music_process = subprocess.Popen(
        ['mpg123', '-q', '--buffer', '1024', '-k', str(frames), filepath],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return jsonify(success=True)

# ═══════════════════════════════════════════════════════════════════════════════
# SHOW
# ═══════════════════════════════════════════════════════════════════════════════
@app.route('/api/show/start')
def start_show():
    global show_running, show_thread
    if show_running:
        return jsonify(success=False, error='Шоу уже идёт')
    show_running = True
    show_thread  = threading.Thread(target=run_show, daemon=True)
    show_thread.start()
    return jsonify(success=True)

@app.route('/api/show/stop')
def stop_show():
    global show_running
    show_running = False
    stop_music()
    all_off()
    return jsonify(success=True)

@app.route('/api/show/status')
def show_status():
    return jsonify(running=show_running)

def play_with_scenario(filename, pre_delay=0):
    global show_running
    filepath = os.path.join(MUSIC_DIR, filename)
    sc_path  = os.path.join(SCENARIOS_DIR, filename.replace('.mp3', '.json'))

    scenario = []
    if os.path.exists(sc_path):
        with open(sc_path, encoding='utf-8') as f:
            sc_raw = json.load(f)
        if sc_raw and isinstance(sc_raw[0], dict) and 'time_ms' in sc_raw[0]:
            scenario = sc_raw

    all_off()
    if pre_delay > 0:
        elapsed = 0
        while elapsed < pre_delay and show_running:
            time.sleep(0.1)
            elapsed += 0.1
    if not show_running:
        return

    stop_music()
    proc = subprocess.Popen(
        ['mpg123', '-q', '--buffer', '1024', filepath],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    start_time = time.time()
    sc_idx     = 0
    done_evt   = threading.Event()

    def sc_loop():
        nonlocal sc_idx
        while proc.poll() is None and show_running:
            elapsed_ms = (time.time() - start_time) * 1000
            while sc_idx < len(scenario) and scenario[sc_idx]['time_ms'] <= elapsed_ms:
                apply_state(scenario[sc_idx]['state'])
                sc_idx += 1
            time.sleep(0.02)
        done_evt.set()

    threading.Thread(target=sc_loop, daemon=True).start()

    while proc.poll() is None and show_running:
        time.sleep(0.1)

    done_evt.wait(timeout=1)
    _kill_proc(proc)
    all_off()

def run_show():
    global show_running
    try:
        tracks = {'greeting': None, 'farewell': None, 'songs': []}
        for f in sorted(os.listdir(MUSIC_DIR)):
            if not f.endswith('.mp3'): continue
            has_sc = os.path.exists(
                os.path.join(SCENARIOS_DIR, f.replace('.mp3', '.json')))
            item = {'name': f, 'has_scenario': has_sc}
            if   f.startswith('greeting_'): tracks['greeting'] = item
            elif f.startswith('farewell_'): tracks['farewell'] = item
            else:                            tracks['songs'].append(item)

        if tracks['greeting'] and show_running:
            play_with_scenario(tracks['greeting']['name'], pre_delay=5)

        first = True
        for song in tracks['songs']:
            if not show_running: break
            delay = 7 if not first else 5
            first = False
            play_with_scenario(song['name'], pre_delay=delay)

        if tracks['farewell'] and show_running:
            play_with_scenario(tracks['farewell']['name'], pre_delay=7)

    except Exception as e:
        print(f'run_show error: {e}')
    finally:
        show_running = False
        all_off()

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════
if __name__ == '__main__':
    try:
        subprocess.run(['sudo', 'iwconfig', 'wlan0', 'power', 'off'],
                       check=False, capture_output=True)
        threading.Thread(target=_servo_worker, daemon=True).start()
        all_off()
        app.run(host='0.0.0.0', port=5000, debug=False, threaded=True)
    except KeyboardInterrupt:
        pass
    finally:
        all_off()
        GPIO.cleanup()
