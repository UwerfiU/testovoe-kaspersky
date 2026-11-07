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
        "NoModelOutputFilter: unexpected record format, record redacted. "
        "logger=%s line=%d template=%r arg_types=%s",
        record.name,
        record.lineno,
        record.msg,
        [type(a).__name__ for a in args],
    )


def _exception_text(record: logging.LogRecord) -> str:
    if not record.exc_info:
        return ""
    if record.exc_text is None:
        try:
            record.exc_text = logging.Formatter().formatException(record.exc_info)
        except Exception:
            return ""
    return record.exc_text or ""


def _strip_exception(record: logging.LogRecord) -> None:
    record.exc_info = None
    record.exc_text = None


class NoModelOutputFilter(logging.Filter):
    PREFIX = "Generated response"

    def filter(self, record: logging.LogRecord) -> bool:
        if getattr(record, "_no_model_output_done", False):
            return True
        if not str(record.msg).startswith(self.PREFIX):
            return True
        try:
            rid, stream_info, _, finish_reason = record.args
        except Exception:
            _report_unexpected_format(record)
            record.msg = f"{self.PREFIX} <redacted>"
            record.args = None
        else:
            record.msg = f"{self.PREFIX} %s%s: output: <redacted>, finish_reason: %s"
            record.args = (rid, stream_info, finish_reason)
        _strip_exception(record)
        record.stack_info = None
        record._no_model_output_done = True
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

    @classmethod
    def _matches(cls, text: str) -> bool:
        low = text.lower()
        return any(p in low for p in cls._PATTERNS)

    @classmethod
    def _redact(cls, record: logging.LogRecord) -> None:
        record.msg = "[REDACTED]"
        record.args = None
        _strip_exception(record)

    def filter(self, record: logging.LogRecord) -> bool:
        try:
            msg = record.getMessage()
        except Exception:
            return False

        if self._matches(msg) or len(msg) > self._MAX_LEN:
            self._redact(record)
            return True

        exc_text = _exception_text(record)
        if exc_text and (self._matches(exc_text) or len(exc_text) > self._MAX_LEN):
            _strip_exception(record)
            if isinstance(record.msg, str):
                record.msg = record.msg + " [traceback redacted]"
        return True
