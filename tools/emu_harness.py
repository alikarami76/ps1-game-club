"""Headless libretro frontend: runs a PS1 game with no window or audio output.

Used to measure gameplay values from the player's own disc. Frames can be saved
to PNG for checking; RAM can be read for vehicle state.
"""
import ctypes as C
import os
import sys

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Built by tools/build_core.sh (never committed). PS1_CORE overrides the path.
_EXT = ".dylib" if sys.platform == "darwin" else (".dll" if os.name == "nt" else ".so")
CORE = os.environ.get("PS1_CORE") or os.path.join(ROOT, "emu/pcsx_rearmed/pcsx_rearmed_libretro" + _EXT)
SYS_DIR = os.path.join(ROOT, "cache/emu/system").encode()

# libretro constants
ENV_GET_CAN_DUPE, ENV_GET_SYSTEM_DIRECTORY, ENV_SET_PIXEL_FORMAT = 3, 9, 10
ENV_GET_VARIABLE, ENV_GET_VARIABLE_UPDATE, ENV_GET_SAVE_DIRECTORY = 15, 17, 31
ENV_GET_LOG_INTERFACE = 27
MEMORY_SYSTEM_RAM = 2
BUTTONS = {"B": 0, "Y": 1, "SELECT": 2, "START": 3, "UP": 4, "DOWN": 5, "LEFT": 6, "RIGHT": 7,
           "A": 8, "X": 9, "L": 10, "R": 11, "L2": 12, "R2": 13}
# PS1 mapping in pcsx_rearmed: B=Cross, A=Circle, Y=Square, X=Triangle


class GameInfo(C.Structure):
    _fields_ = [("path", C.c_char_p), ("data", C.c_void_p), ("size", C.c_size_t), ("meta", C.c_char_p)]


class Variable(C.Structure):
    _fields_ = [("key", C.c_char_p), ("value", C.c_char_p)]


ENV_CB = C.CFUNCTYPE(C.c_bool, C.c_uint, C.c_void_p)
VIDEO_CB = C.CFUNCTYPE(None, C.c_void_p, C.c_uint, C.c_uint, C.c_size_t)
AUDIO_CB = C.CFUNCTYPE(None, C.c_int16, C.c_int16)
AUDIO_BATCH_CB = C.CFUNCTYPE(C.c_size_t, C.c_void_p, C.c_size_t)
POLL_CB = C.CFUNCTYPE(None)
STATE_CB = C.CFUNCTYPE(C.c_int16, C.c_uint, C.c_uint, C.c_uint, C.c_uint)
LOG_CB = C.CFUNCTYPE(None, C.c_int, C.c_char_p)


class Emulator:
    def __init__(self, cue_path, options=None):
        os.makedirs(SYS_DIR, exist_ok=True)
        self.lib = C.CDLL(CORE)
        self.options = {b"pcsx_rearmed_bios": b"HLE"}
        self.options.update(options or {})
        self._opt_bufs = {}
        self.pixel_format = 0
        self.frame = None
        self.pressed = set()
        self.frames_run = 0
        self._cbs = [ENV_CB(self._env), VIDEO_CB(self._video), AUDIO_CB(lambda l, r: None),
                     AUDIO_BATCH_CB(lambda d, n: n), POLL_CB(lambda: None), STATE_CB(self._state)]
        self._log_cb = LOG_CB(lambda level, msg: None)
        lib = self.lib
        lib.retro_set_environment(self._cbs[0])
        lib.retro_init()
        lib.retro_set_video_refresh(self._cbs[1])
        lib.retro_set_audio_sample(self._cbs[2])
        lib.retro_set_audio_sample_batch(self._cbs[3])
        lib.retro_set_input_poll(self._cbs[4])
        lib.retro_set_input_state(self._cbs[5])
        self._path = cue_path.encode()
        info = GameInfo(self._path, None, 0, None)
        lib.retro_load_game.restype = C.c_bool
        if not lib.retro_load_game(C.byref(info)):
            raise RuntimeError("core refused to load the game")
        lib.retro_get_memory_data.restype = C.c_void_p
        lib.retro_get_memory_size.restype = C.c_size_t
        lib.retro_serialize_size.restype = C.c_size_t
        lib.retro_serialize.restype = C.c_bool
        lib.retro_unserialize.restype = C.c_bool

    # --- callbacks
    def _env(self, cmd, data):
        cmd &= 0xFFFF
        if cmd in (ENV_GET_SYSTEM_DIRECTORY, ENV_GET_SAVE_DIRECTORY):
            C.cast(data, C.POINTER(C.c_char_p))[0] = SYS_DIR
            return True
        if cmd == ENV_SET_PIXEL_FORMAT:
            self.pixel_format = C.cast(data, C.POINTER(C.c_int))[0]
            return True
        if cmd == ENV_GET_CAN_DUPE:
            C.cast(data, C.POINTER(C.c_bool))[0] = True
            return True
        if cmd == ENV_GET_VARIABLE:
            var = C.cast(data, C.POINTER(Variable))[0]
            val = self.options.get(var.key)
            if val is None:
                return False
            buf = self._opt_bufs.setdefault(val, C.create_string_buffer(val))
            C.cast(data, C.POINTER(Variable))[0].value = C.cast(buf, C.c_char_p).value
            return True
        if cmd == ENV_GET_VARIABLE_UPDATE:
            C.cast(data, C.POINTER(C.c_bool))[0] = False
            return True
        if cmd == ENV_GET_LOG_INTERFACE:
            C.cast(data, C.POINTER(LOG_CB))[0] = self._log_cb
            return True
        return False

    def _video(self, data, w, h, pitch):
        if not data:
            return
        buf = C.string_at(data, pitch * h)
        if self.pixel_format == 1:  # XRGB8888
            arr = np.frombuffer(buf, np.uint8).reshape(h, pitch // 4, 4)[:, :w]
            self.frame = arr[..., [2, 1, 0]].copy()
        else:  # RGB565 or 0RGB1555
            px = np.frombuffer(buf, "<u2").reshape(h, pitch // 2)[:, :w].astype(np.uint32)
            if self.pixel_format == 2:  # RGB565
                r, g, b = (px >> 11) & 31, (px >> 5) & 63, px & 31
                self.frame = np.dstack([r << 3, g << 2, b << 3]).astype(np.uint8)
            else:
                r, g, b = (px >> 10) & 31, (px >> 5) & 31, px & 31
                self.frame = np.dstack([r << 3, g << 3, b << 3]).astype(np.uint8)

    def _state(self, port, device, index, button):
        if port != 0 or device != 1:
            return 0
        return 1 if button in self.pressed else 0

    # --- control
    def run(self, frames=1, buttons=()):
        self.pressed = {BUTTONS[b] for b in buttons}
        for _ in range(frames):
            self.lib.retro_run()
            self.frames_run += 1
        self.pressed = set()

    def tap(self, button, hold=4, after=20):
        self.run(hold, [button])
        self.run(after)

    def ram(self):
        ptr = self.lib.retro_get_memory_data(MEMORY_SYSTEM_RAM)
        size = self.lib.retro_get_memory_size(MEMORY_SYSTEM_RAM)
        return np.frombuffer(C.string_at(ptr, size), np.uint8)

    def save_state(self, path):
        size = self.lib.retro_serialize_size()
        buf = C.create_string_buffer(size)
        assert self.lib.retro_serialize(buf, size)
        open(path, "wb").write(buf.raw)

    def load_state(self, path):
        data = open(path, "rb").read()
        assert self.lib.retro_unserialize(data, len(data))

    def screenshot(self, path):
        if self.frame is not None:
            Image.fromarray(self.frame).save(path)
