import os


if os.environ.get("DST_COVERAGE") == "1":
    import dst_coverage

    dst_coverage.install()
