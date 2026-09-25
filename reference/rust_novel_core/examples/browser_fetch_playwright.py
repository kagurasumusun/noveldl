#!/usr/bin/env python3
"""Fetch a dynamic/challenge-protected novel page with a real Playwright browser.

Usage:
  NOVELDL_BROWSER_FETCH_CMD="python3 examples/browser_fetch_playwright.py {url}" \
    cargo run --example live_site_probe -- https://novelup.plus/story/459438001

The script prints final HTML to stdout and diagnostics to stderr so it can be used by
Downloader's NOVELDL_BROWSER_FETCH_CMD fallback without changing Rust dependencies.
"""

from __future__ import annotations

import argparse
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description="Fetch one URL with Playwright Chromium")
    parser.add_argument("url")
    parser.add_argument("--timeout-ms", type=int, default=60_000)
    parser.add_argument("--settle-ms", type=int, default=5_000)
    parser.add_argument("--headed", action="store_true", help="Run a headed browser instead of headless")
    args = parser.parse_args()

    try:
        from playwright.sync_api import TimeoutError as PlaywrightTimeoutError
        from playwright.sync_api import sync_playwright
    except Exception as exc:  # pragma: no cover - environment helper
        print(
            "Playwright is not installed. Install with: python3 -m pip install playwright && python3 -m playwright install chromium",
            file=sys.stderr,
        )
        print(f"import error: {exc}", file=sys.stderr)
        return 127

    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            headless=not args.headed,
            args=[
                "--disable-blink-features=AutomationControlled",
                "--no-sandbox",
            ],
        )
        try:
            context = browser.new_context(
                ignore_https_errors=True,
                locale="ja-JP",
                user_agent=(
                    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) "
                    "Chrome/148.0.0.0 Safari/537.36"
                ),
            )
            page = context.new_page()
            try:
                response = page.goto(args.url, wait_until="domcontentloaded", timeout=args.timeout_ms)
            except PlaywrightTimeoutError:
                response = None
                print(f"browser fetch navigation timed out: {args.url}", file=sys.stderr)
            page.wait_for_timeout(args.settle_ms)
            html = page.content()
            status = response.status if response is not None else "unknown"
            title = page.title()
            print(f"browser fetch status={status} final_url={page.url} title={title!r}", file=sys.stderr)
            if not html.strip():
                print("browser fetch returned empty HTML", file=sys.stderr)
                return 1
            if isinstance(status, int) and status >= 400:
                print(
                    "browser fetch reached the site but received an HTTP error page; "
                    "this is usually a CDN/WAF/IP block, not a parser selector failure",
                    file=sys.stderr,
                )
                return 2
            lowered = html[:4096].lower()
            if "the request could not be satisfied" in lowered or "cloudfront" in lowered:
                print(
                    "browser fetch received a CloudFront error page; "
                    "the current network is blocked before novel HTML is served",
                    file=sys.stderr,
                )
                return 2
            sys.stdout.write(html)
            return 0
        finally:
            browser.close()


if __name__ == "__main__":
    raise SystemExit(main())
