# Minimal Nixpkgs expression for the nexus e2e browser suite.
#
# Validation-only: this file provides Playwright driving headless Chromium on
# NixOS. It must never alter Nexus runtime dependencies — nothing here feeds
# `gleam run` / `gleam test` / the devShell used to build the server; it only
# provisions a *separate* shell for the e2e checks.
#
# Design notes (kept deliberately small to avoid heavy transitive deps):
#
#   - Node.js from nixpkgs runs the Playwright npm package (pinned in
#     e2e/package.json). The npm package is pure JS — no browser build.
#   - The browser comes from nixpkgs' Chromium, passed to Playwright via
#     `executablePath` (see e2e/browser.spec.mjs), which avoids both the
#     "download a Chrome-for-Testing bundle" path and nixpkgs' python
#     `playwright` package (that one builds all browser engines and drags a
#     large dependency closure).
#   - `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` keeps `npm install` from fetching
#     browsers at install time.
#
# Usage:
#
#     nix-shell e2e/playwright.nix
#     npm --prefix e2e install
#     node e2e/browser.spec.mjs
#
# On this machine the harness also provides a warm
# `~/.cache/ms-playwright/chromium-*`; browser.spec.mjs falls back to the
# Playwright-managed browser when NIX_PLAYWRIGHT_CHROMIUM is unset, so the
# suite runs unchanged outside NixOS.

{ pkgs ? import <nixpkgs> { } }:

let
  node = pkgs.nodejs_24;
  chromium = pkgs.chromium;
in
pkgs.mkShell {
  name = "nexus-e2e";
  packages = [ node chromium ];

  PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";
  NIX_PLAYWRIGHT_CHROMIUM = "${chromium}/bin/chromium";

  shellHook = ''
    echo "node $(node --version)"
    echo "chromium ${chromium.version} at ${chromium}/bin/chromium"
    echo "run: npm --prefix e2e install && node e2e/browser.spec.mjs"
  '';
}
