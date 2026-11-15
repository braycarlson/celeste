set shell := ["sh", "-c"]
set windows-shell := ["powershell.exe", "-c"]

[doc('Compile every artifact and type-check the host runner and the guest Python SDK')]
check:
    zig build check
    uv run --directory python ty check src tests ../guest/sdk/python

[doc('Run the continuous integration pipeline')]
ci:
    zig build ci

[doc('Format build.zig, every source file, the host runner, and the guest Python SDK')]
fmt:
    zig fmt build.zig src
    uv run --directory python ruff format . ../guest/sdk/python

[doc('Build the guest programs')]
guest:
    zig build guest

[doc('Lint build.zig, every source file, the host runner, and the guest Python SDK with tigerstyle-lsp and ruff')]
lint:
    tigerstyle-lsp check build.zig guest/sdk/python python/src python/tests src --format concise
    uv run --directory python ruff check . ../guest/sdk/python
    uv run --directory python ruff format --check . ../guest/sdk/python

[default]
[doc('List every recipe')]
list:
    @just --list

[doc('Run celeste: just run [arguments]')]
run *arguments:
    zig build run -- {{ arguments }}

[doc('Run every test suite and the format check')]
test:
    zig build test
    uv run --directory python pytest

[doc('Run the host runner and guest Python SDK tests')]
test-python:
    uv run --directory python pytest
