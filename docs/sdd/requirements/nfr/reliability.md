# Reliability Requirements

## NFR-REL-001: Timeout Guarantee

All `tmux wait-for` invocations shall have a timeout (default 600 seconds). After timeout, an error status shall be notified to the parent.

## NFR-REL-002: Abnormal Termination Signal Guarantee

Even when a child pane process terminates abnormally, a signal shall be sent to the parent pane. The wrapper script shall catch the EXIT signal via `trap`.

## NFR-REL-003: Result File Integrity

Result files shall be written atomically (temporary file → rename) to prevent reading of incomplete data.
