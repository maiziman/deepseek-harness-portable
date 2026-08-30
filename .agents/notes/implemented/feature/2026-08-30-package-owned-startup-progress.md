# Agent Note: Package-owned first-run progress

Status: implemented

English | [中文](2026-08-30-package-owned-startup-progress.zh.md)

## Problem

The first Web-profile launch prepares hundreds of dependency links before the local service is ready. Fixed timers do not describe that work, while counting every profile fallback link can include packages resolved from a parent `node_modules` directory on the build machine or in the user's extraction path.

## Decision

The desktop shell opens an isolated loading window immediately and advances through runtime, profile, component, service, and ready stages. The build runs the packaged application once and records the number of profile links whose resolved targets are inside the portable package's own `app/node_modules`. Runtime progress applies the same realpath filter, so unrelated packages above the portable directory cannot change the completed count. The final ZIP verifier starts from an empty home and captures the displayed component numerator and denominator plus a machine-readable state record. It requires the rendered total, the manifest total, the measured package-owned links, the official service URL, and the final UI to agree. A real-filesystem test creates package-owned junctions and an external control junction to prove the filter on Windows.

## Alternatives considered

- A time-based animation can look smooth but cannot represent slow disks, antivirus scans, or different machines.
- Counting all files in the distribution measures archive size rather than profile initialization.
- Counting every fallback link allows an enclosing development workspace to distort progress.

## Consequences

First-run progress is derived from completed package-owned components and remains stable after the ZIP is moved or extracted under another directory. Optional packages found outside the distribution do not make the meter finish early or report a total larger than its manifest. An upstream dependency-closure change is picked up by the next real build instead of requiring a hardcoded component count.
