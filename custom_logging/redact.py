from __future__ import annotations

import logging

_diagnostic = logging.getLogger("custom_logging.diagnostics")
_format_warning_emitted = False


def _report_unexpected_format(record: logging.LogRecord) -> None:
    global _format_warning_emitted
    if _format_warning_emitted:
        return
    _format_warning_emitted = True
    args = record.args if isinstance(record.args, tuple) else ()
    _diagnostic.warning(
        "NoModelOutputFilter: unexpected record format, record dropped. "
        "logger=%s line=%d template=%r arg_types=%s",
        record.name,
        record.lineno,
        record.msg,
        [type(a).__name__ for a in args],
    )


class NoModelOutputFilter(logging.Filter):
    PREFIX = "Generated response"

    def filter(self, record: logging.LogRecord) -> bool:
        if not str(record.msg).startswith(self.PREFIX):
            return True
        try:
            rid, stream_info, _, finish_reason = record.args
        except Exception:
            _report_unexpected_format(record)
            return False
        record.msg = f"{self.PREFIX} %s%s: output: <redacted>, finish_reason: %s"
        record.args = (rid, stream_info, finish_reason)
        return True


class SensitiveContentFilter(logging.Filter):
    _PATTERNS = (
        "input prompt",
        "json body",
        "received messages request",
        "messages response",
        "prompt: ",
    )
    _MAX_LEN = 2000

    def filter(self, record: logging.LogRecord) -> bool:
        try:
            msg = record.getMessage().lower()
        except Exception:
            return False
        if any(p in msg for p in self._PATTERNS) or len(msg) > self._MAX_LEN:
            record.msg = "[REDACTED]"
            record.args = None
        return True
