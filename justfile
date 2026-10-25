set shell := ["sh", "-c"]
set windows-shell := ["powershell.exe", "-c"]

[doc('Compile every artifact without running it')]
check:
    zig build check

[doc('Compile every artifact and check the format')]
ci:
    zig build ci

[doc('Format build.zig and every source file')]
fmt:
    zig fmt build.zig src

[doc('Build the guest programs')]
guest:
    zig build guest

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
