# Runner is framework; Dockerfile is consumer-owned

The AFK Runner's orchestration (shell scripts, smoke tests, tracker-snapshot interface) lives in Formann at `framework/runner/`. The Dockerfile that defines the sandbox container's toolchain lives in the consumer repo, not in Formann. The Installer scaffolds an initial Dockerfile when a consumer first sets up. This draws the framework/consumer seam exactly at "what goes inside the container," because container contents (JDK version, build tool, OS packages) are intrinsically project-specific.

## Considered options

- **All-in-Formann with overlay mechanism** (per-consumer Dockerfile overlay applied at build time). Rejected: heavyweight for v0 — no second overlay exists yet to validate the abstraction. Premature, YAGNI.
- **All-in-Formann with parameterized base** (env vars / build args select toolchain). Rejected: bakes assumptions about toolchain shape. What fits Java/Maven won't fit Go/cargo or Python/uv; the parameter set is unbounded.
- **All-in-consumer** (consumer maintains both Dockerfile *and* runner scripts). Rejected: defeats the purpose of Formann. Framework duplication across consumers would become a fork-and-drift problem within months.

## Consequences

- Framework runner scripts invoke `docker build` against a path the consumer controls (conventional: `runner/Dockerfile` in the consumer).
- Cross-consumer differences are localized to the Dockerfile and any Dockerfile-companions. The orchestration stays one source of truth.
- Maven-shaped cache logic in `framework/runner/lib.sh` (the `ensure-mvn-cache.sh` helper, the per-feature Maven cache volume) is part of the v0 *Maven-assumption*: every consumer uses Maven. This is the natural abstraction seam when a non-Maven consumer arrives — at that point, the cache becomes a generic "build-tool cache" with the Maven implementation as one strategy. YAGNI until then.
- The installer's Dockerfile-scaffolding step is non-trivial: it must produce a working Dockerfile for the consumer's toolchain. v0 ships a Maven template; sister-company adoption of non-Maven stacks will force template work later.
