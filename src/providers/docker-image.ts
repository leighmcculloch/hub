/**
 * The image a Docker session starts from: the standard setup, baked in ahead of
 * time instead of run on every container.
 *
 * The setup is not written twice. The bootstrap's own fragments — the packages,
 * Node, pi — are the Dockerfile's `RUN`, so there is one definition of what a
 * machine needs and the image is only a place to have already done it. Those
 * fragments each check before they act, so a container built from this image
 * still runs them at connect time and finds nothing left to do.
 *
 * The tag is a hash of exactly what goes into the image, which makes the cache
 * correct by construction: change the setup and the tag changes with it, so a
 * stale image is never reused and an unchanged one is never rebuilt.
 */

import { ENSURE_NODE, ENSURE_PI, INSTALL_PREREQUISITES } from "../model/bootstrap.ts";

/** What the session image is built on. Plain, on purpose. */
export const BASE_IMAGE = "ubuntu:24.04";

/** The image name; the tag is the setup's hash. */
export const IMAGE_REPOSITORY = "hub-session";

/**
 * Where a container starts. `ubuntu` sets no `WORKDIR`, so every `docker exec`
 * — including the one that starts the tmux server, and so every pane that
 * server opens afterwards — begins at `/`. The image runs as root, so root's
 * home is the answer.
 */
export const HOME_DIRECTORY = "/root";

/**
 * The setup, as one script for the build to run.
 *
 * No `set -e`: the fragments handle their own failures, and several are
 * deliberately allowed to fail on an image that already has what they install.
 * The check at the end is what decides whether the build succeeded — an image
 * without pi is worse than no image, because it fails later and further away.
 */
export function imageSetupScript(): string {
  return `#!/bin/sh
${INSTALL_PREREQUISITES}
${ENSURE_NODE}
${ENSURE_PI}
command -v pi >/dev/null 2>&1 || { echo "hub: pi did not install" >&2; exit 1; }
`;
}

/**
 * `COPY` and run, rather than a heredoc `RUN`: heredocs need BuildKit, and
 * there is no reason to require it.
 */
export function dockerfile(): string {
  return `FROM ${BASE_IMAGE}
ENV DEBIAN_FRONTEND=noninteractive
COPY setup.sh /tmp/hub-setup.sh
RUN sh /tmp/hub-setup.sh && rm -f /tmp/hub-setup.sh
WORKDIR ${HOME_DIRECTORY}
CMD ["sleep", "infinity"]
`;
}

/** The tag for a given build: the same inputs always name the same image. */
export async function imageTag(
  file: string = dockerfile(),
  setup: string = imageSetupScript(),
): Promise<string> {
  return `${IMAGE_REPOSITORY}:${await digest(`${file}\n${setup}`)}`;
}

/** Twelve hex characters of SHA-256: a tag, not a signature. */
async function digest(text: string): Promise<string> {
  const hash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(hash).slice(0, 6))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}
