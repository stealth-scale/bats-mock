# Security policy

## Supported versions

The latest tagged version is supported.

## Reporting a vulnerability

Report a vulnerability through GitHub's private vulnerability reporting on this repository,
under its Security tab. Do not open a public issue. We acknowledge a report within three
working days and publish a fix before any disclosure.

## Evaluation of mock content

An action passed to `mock` is shell code by design and is evaluated when the mock is called.
Command names are checked against `[a-zA-Z0-9._:-]` before a function is defined, and the
framework's own names are refused. Arguments of a call are matched and logged as text and
are never evaluated. The tests under `security:` in `tests/mock.bats` check these
properties.
