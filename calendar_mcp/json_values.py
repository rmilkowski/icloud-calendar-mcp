# SPDX-FileCopyrightText: 2026 Robert Milkowski
# SPDX-License-Identifier: AGPL-3.0-only
"""Validate decoded JSON values without exposing caller-supplied data."""

import math


def validate_json(value, *, max_depth=20):
    def string(value):
        try:
            value.encode("utf-8")
        except UnicodeError:
            raise ValueError("Invalid Unicode in JSON string") from None

    def visit(item, depth=0):
        if depth > max_depth:
            raise ValueError("JSON nesting exceeds limit")
        if isinstance(item, str):
            string(item)
        elif isinstance(item, float):
            if not math.isfinite(item):
                raise ValueError("Non-finite JSON number")
        elif item is None or isinstance(item, (bool, int)):
            return
        elif isinstance(item, dict):
            for key, child in item.items():
                if not isinstance(key, str):
                    raise ValueError("JSON object keys must be strings")
                string(key)
                visit(child, depth + 1)
        elif isinstance(item, list):
            if len(item) > 10000:
                raise ValueError("JSON array exceeds limit")
            for child in item:
                visit(child, depth + 1)
        else:
            raise ValueError("Invalid JSON value type")

    visit(value)
