#!/usr/bin/env python3
"""Send one fixed verb to a running VM's guest control service over its serial socket.
Usage: vm_control.py RUN_DIR VERB [text]
The guest's PL011 serial input stalls if more than its 16-byte FIFO arrives at once, so
bytes are written in small chunks."""
import base64, os, socket, sys, threading, time
from pathlib import Path

_cwd_lock = threading.Lock()  # the working directory is process-wide
VERBS = ('VM_POWEROFF', 'VM_STATUS', 'VM_POINTER', 'VM_POINTER_ACCEL_OFF', 'VM_AUDIO_DIAG',
         'VM_PLAY_TEST', 'VM_POINTER_LOCATION 0', 'VM_POINTER_LOCATION 1', 'VM_PASTE', 'VM_PASTE1')


def send(run_dir, verb, text=None):
    line = verb if text is None else verb + ' ' + base64.b64encode(text.encode()).decode()
    data = (line + '\n').encode()
    # Connect by a short relative path: macOS limits socket paths to 104 bytes.
    with socket.socket(socket.AF_UNIX) as s:
        with _cwd_lock:
            cwd = os.getcwd()
            os.chdir(run_dir)
            try: s.connect('serial.sock')
            finally: os.chdir(cwd)
        for i in range(0, len(data), 8):
            s.sendall(data[i:i + 8]); time.sleep(.03)


if __name__ == '__main__':
    assert sys.argv[2] in VERBS or sys.argv[2].startswith('VM_DENSITY ')
    send(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
