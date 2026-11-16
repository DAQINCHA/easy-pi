/**
 * Where this machine keeps easy-pi-webui's runtime state: uploads, archive /
 * pin records and the local settings file. Code stays in the project folder;
 * everything mutable lives in one directory outside it.
 *
 * Override with EASY_PI_STATE_DIR (a leading `~` expands to the home dir).
 * Nothing is created here — callers mkdir on demand.
 */
import { homedir } from "node:os";
import { join, resolve } from "node:path";

export const DEFAULT_STATE_DIR_NAME = ".easy-pi";

export function resolveStateDir() {
  const raw = String(process.env.EASY_PI_STATE_DIR || "").trim();
  if (!raw) return join(homedir(), DEFAULT_STATE_DIR_NAME);
  const expanded = raw === "~" || raw.startsWith("~/")
    ? join(homedir(), raw.slice(1))
    : raw;
  return resolve(expanded);
}
