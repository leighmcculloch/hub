/** One `KEY=VALUE` pair set on the VM host at creation time. */
export interface EnvVar {
  key: string;
  value: string;
}

/**
 * Combine several sources of variables, later lists winning on a shared key.
 * Nameless rows are dropped, since they can't be set on the VM.
 *
 * Order is the point: the model configuration has to be able to blank a token
 * the environment sets, and passing the same key to a provider twice leaves
 * which one wins up to the provider.
 */
export function mergeEnv(lists: EnvVar[][]): EnvVar[] {
  const merged: EnvVar[] = [];
  for (const variable of lists.flat()) {
    if (!variable.key) continue;
    const existing = merged.findIndex((entry) => entry.key === variable.key);
    if (existing >= 0) merged[existing] = { ...merged[existing], value: variable.value };
    else merged.push({ key: variable.key, value: variable.value });
  }
  return merged;
}

/** Lenient decode: the config file invites hand-editing. */
export function envVarsFrom(value: unknown): EnvVar[] {
  if (!Array.isArray(value)) return [];
  return value
    .filter((entry): entry is Record<string, unknown> =>
      typeof entry === "object" && entry !== null
    )
    .map((entry) => ({
      key: typeof entry.key === "string" ? entry.key : "",
      value: typeof entry.value === "string" ? entry.value : "",
    }));
}
