from __future__ import annotations

import os


if os.environ.get('CELESTE_COVERAGE') == '1':
    import celeste_coverage

    celeste_coverage.install()
