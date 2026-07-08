---
name: krakendesign
description: Agent-only procedure for KrakenDesign, the cockpit-native review dock firstmate uses to show the captain a rendered UI, design, mockup, or structured visual report. Use before producing or relaying a rich HTML report, a rendered UI or design or mockup, an artifact review, a visual comparison, or a multi-option visual decision surface for the captain. Covers registering an artifact, polling and resolving captain comments, the self-contained-HTML rule, storing the artifact under data/<id>/, and when a screenshot is acceptable.
user-invocable: false
metadata:
  internal: true
---

# krakendesign

Load this before showing the captain any rendered UI, design, mockup, or structured visual report.
KrakenDesign is the cockpit-native review dock: it registers one HTML file as an artifact the captain annotates in place, and it reads the captain's pinned comments back to you.
It replaced the retired `lavish-axi`/KrakenView flow; `lavish-axi` still forwards to `krakendesign` as a backward-compatible alias, but call `krakendesign` directly.
There is no separate browser window - the review lives in the cockpit dock, and screenshots are never the captain's review surface (see below).

## When it fires

Register a KrakenDesign artifact, share its review URL, and poll for feedback before you show the captain, whenever you are about to present:

- a rendered UI, design, or mockup;
- a structured visual report worth annotating (multiple findings, options, or a plan);
- a visual comparison or a multi-option visual decision surface.

Plain chat still handles a focused answer or a yes/no.
Use KrakenDesign the moment the thing to review is visual or structured enough that the captain would want to point at it.

## Commands

The tool operates on one HTML file; the artifact id is derived deterministically from that file's absolute path.

- `krakendesign <file.html> [--title "..."]` registers (or re-registers) the artifact for review.
- `krakendesign poll <file.html> [--wait]` prints new captain comments since the last poll; `--wait` blocks until a comment arrives.
- `krakendesign list` lists registered artifacts with their open-comment counts and exact review URLs.
- `krakendesign resolve <file.html> [--reply "..."]` marks the current comments consumed, with an optional reply back to the captain.

The review URL is `<COCKPIT>/helm.html?kd=<id>`, where `<COCKPIT>` defaults to `http://127.0.0.1:8787` (override with `KRAKENDESIGN_URL`).
`krakendesign list` prints the exact `helm.html?kd=<id>` URL for each artifact; relay that URL to the captain when you hand off a review.

## The self-contained-HTML rule

Registration copies only the one HTML file's text into the artifact store; it does not copy sibling CSS, JS, images, fonts, or live app/API state.
So the artifact must be a single self-contained HTML file: inline all CSS and JS, embed images and fonts as `data:` URIs, and freeze any board/sample data directly into the markup.
A live multi-file app pointed at a test port will not render in the dock - its relative assets and API calls resolve nowhere once the HTML is snapshotted.
To turn a live cockpit render at a URL into a self-contained artifact, use `bin/fm-kd-snapshot.sh` (it renders headless, inlines CSS and images, freezes deterministic sample data, and writes one `.kd.html`) rather than hand-building the artifact.

## Where the artifact lives

Store the artifact under the task's own `data/<id>/` directory, for example `data/<id>/<name>.kd.html`, not in the disposable worktree or `/tmp`.
The artifact id is derived from the file's absolute path, so a stable path keeps the same review thread alive across polls, and `data/` survives task teardown while a treehouse worktree does not.

## Screenshots

A screenshot (PNG) is acceptable only as firstmate's own verification that a render looks right - never as the captain's review surface.
The captain reviews and annotates in the KrakenDesign dock, so a folder of PNGs is not a substitute for a registered artifact.
If a render genuinely cannot be represented as a single self-contained HTML file, say so plainly and explain why, rather than silently falling back to screenshots.
