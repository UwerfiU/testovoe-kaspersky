import io
import logging
import sys

sys.path.insert(0, ".")

from custom_logging.redact import NoModelOutputFilter, SensitiveContentFilter


def make_logger():
    out = io.StringIO()
    handler = logging.StreamHandler(out)
    handler.addFilter(NoModelOutputFilter())
    handler.addFilter(SensitiveContentFilter())
    logger = logging.getLogger("test.vllm")
    logger.handlers = [handler]
    logger.setLevel(logging.DEBUG)
    logger.propagate = False

    diag_out = io.StringIO()
    diag_handler = logging.StreamHandler(diag_out)
    diag_logger = logging.getLogger("custom_logging.diagnostics")
    diag_logger.handlers = [diag_handler]
    diag_logger.setLevel(logging.WARNING)
    diag_logger.propagate = False
    return logger, out, diag_out


def main():
    failures = []

    def check(name, cond):
        print(("PASS" if cond else "FAIL"), name)
        if not cond:
            failures.append(name)

    logger, out, diag_out = make_logger()

    logger.info(
        "Generated response %s%s: output: %r, finish_reason: %s",
        "chatcmpl-1", "", "SECRET-MARKER-123", "stop",
    )
    text = out.getvalue()
    check("output redacted", "<redacted>" in text)
    check("model output not leaked", "SECRET-MARKER-123" not in text)

    out.truncate(0); out.seek(0)
    logger.info("Received request %s: params: %s.", "chatcmpl-1", "SamplingParams(...)")
    text = out.getvalue()
    check("request fact preserved", "Received request chatcmpl-1" in text)

    out.truncate(0); out.seek(0)
    logger.debug("Input prompt: %s", "SECRET-PROMPT-456")
    text = out.getvalue()
    check("debug prompt redacted", "[REDACTED]" in text and "SECRET-PROMPT-456" not in text)

    out.truncate(0); out.seek(0); diag_out.truncate(0); diag_out.seek(0)
    logger.info("Generated response %s", ("only-one-arg",))
    check("unexpected format dropped", "only-one-arg" not in out.getvalue())
    check("diagnostic emitted", "unexpected record format" in diag_out.getvalue())

    diag_out.truncate(0); diag_out.seek(0)
    logger.info("Generated response %s", ("another-bad-format",))
    check("diagnostic deduplicated", diag_out.getvalue() == "")

    print()
    if failures:
        print("FAILED:", failures)
        sys.exit(1)
    print("ALL OK")


if __name__ == "__main__":
    main()
