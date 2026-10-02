#!/usr/bin/env python3
"""Release and watchdog checks: releasing the hotkey must always unblock recorder.text()."""

import threading
import time

import whisper_dictate as wd


class FakeRecorder:
    """Records which unblock path was taken. is_recording mirrors RealtimeSTT.

    abort() blocks like the real one, which only returns once a live text()
    call sets its event — this is what must not park the calling thread.
    """

    def __init__(self, is_recording):
        self.is_recording = is_recording
        self.calls = []
        self.aborting = threading.Event()
        self.release_abort = threading.Event()

    def stop(self):
        self.calls.append("stop")

    def set_microphone(self, on):
        pass

    def abort(self):
        self.calls.append("abort")
        self.aborting.set()
        self.release_abort.wait()


def _bare_dictation(recorder_is_recording=True):
    """A WhisperDictation with state initialised but no model loaded."""
    d = object.__new__(wd.WhisperDictation)
    d.recorder = FakeRecorder(recorder_is_recording)
    d.is_recording = False
    d.is_processing = False
    d.lock = threading.Lock()
    d._processing_deadline = 0
    d._target_window = None
    return d


def test_release_mid_phrase_stops():
    d = _bare_dictation(recorder_is_recording=True)
    d.is_recording = True
    d.is_processing = True

    d.stop_recording()

    assert d.recorder.calls == ["stop"], (
        f"expected stop() to commit the captured phrase, got {d.recorder.calls}"
    )


def test_release_between_phrases_interrupts():
    d = _bare_dictation(recorder_is_recording=False)
    d.is_recording = True
    d.is_processing = True

    d.stop_recording()

    assert d.recorder.aborting.wait(timeout=2), (
        f"expected abort() to unblock text(), got {d.recorder.calls}; "
        "stop() is ignored by the start-event wait, so the session would wedge"
    )
    d.recorder.release_abort.set()


def test_release_does_not_park_the_calling_thread():
    """A hanging abort() must not take the evdev listener down with it."""
    d = _bare_dictation(recorder_is_recording=False)
    d.is_recording = True
    d.is_processing = True

    returned = threading.Event()

    def caller():
        d.stop_recording()
        returned.set()

    threading.Thread(target=caller, daemon=True).start()

    assert returned.wait(timeout=2), (
        "stop_recording() blocked inside recorder.abort(); "
        "on the evdev thread this stops all hotkey detection until restart"
    )
    d.recorder.release_abort.set()


def test_release_rearms_tighter_transcribe_deadline():
    d = _bare_dictation()
    d.is_recording = True
    d.is_processing = True
    d._processing_deadline = time.time() + wd.RECORDING_TIMEOUT

    d.stop_recording()

    remaining = d._processing_deadline - time.time()
    assert remaining <= wd.TRANSCRIBE_TIMEOUT, (
        f"transcription inherited a {remaining:.0f}s deadline; "
        "a wedged decode would hold is_processing and block later hotkey presses"
    )
    assert d.is_processing, "stop_recording must leave the transcription stage armed"


def test_long_recording_is_not_aborted():
    d = _bare_dictation()
    d.is_recording = True
    d.is_processing = True
    d._processing_deadline = time.time() + wd.RECORDING_TIMEOUT

    assert not d._is_stuck(), "a recording well inside RECORDING_TIMEOUT was aborted"
    assert d.is_recording


def test_expired_deadline_still_aborts():
    d = _bare_dictation()
    d.is_recording = False
    d.is_processing = True
    d._processing_deadline = time.time() - 1

    assert d._is_stuck(), "expired deadline did not trip the watchdog"
    assert not d.is_processing


if __name__ == "__main__":
    for name, case in sorted(globals().items()):
        if name.startswith("test_"):
            case()
    print("ok")
