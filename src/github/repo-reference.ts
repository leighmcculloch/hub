/**
 * Interpreting whatever the user typed or pasted into the "owner/repo" field.
 *
 * The field only ever asked for `owner/repo`, but the obvious thing to do with
 * it is paste a GitHub URL from the browser. That used to be accepted as-is —
 * it contains a slash — and became a clone path of
 * `https://github.int.exe.xyz/https://github.com/owner/repo.git`, which fails.
 */

/** `owner/repo`, or null when the text isn't a repository reference. */
export function normalizeRepo(text: string): string | null {
  let rest = text.trim();
  if (!rest) return null;

  // A recognisable prefix means the rest is a URL path, so trailing segments —
  // /tree/main, /pull/12 — are part of a deep link and can be dropped. Without
  // one, the text is taken literally and must already be exactly owner/repo;
  // trimming a third component there would be guessing at what was meant.
  const stripped = stripPrefix(rest);
  const hadPrefix = stripped !== null;
  if (stripped !== null) rest = stripped;

  if (rest.endsWith("/")) rest = rest.slice(0, -1);
  if (rest.endsWith(".git")) rest = rest.slice(0, -".git".length);

  const parts = rest.split("/");
  if (!hadPrefix && parts.length !== 2) return null;
  if (parts.length < 2 || !parts[0] || !parts[1]) return null;
  return `${parts[0]}/${parts[1]}`;
}

/** The text with a scheme, SSH form, or bare host removed, or null if none. */
function stripPrefix(text: string): string | null {
  for (const scheme of ["https://", "http://", "ssh://", "git://"]) {
    if (!text.startsWith(scheme)) continue;
    const rest = text.slice(scheme.length);
    // The host is now the first path component.
    const slash = rest.indexOf("/");
    return slash === -1 ? "" : rest.slice(slash + 1);
  }
  // git@github.com:owner/repo.git
  const at = text.indexOf("@");
  const colon = text.indexOf(":");
  const slash = text.indexOf("/");
  if (at !== -1 && colon !== -1 && at < colon && (slash === -1 || slash > colon)) {
    return text.slice(colon + 1);
  }
  for (const host of ["github.com/", "www.github.com/"]) {
    if (text.startsWith(host)) return text.slice(host.length);
  }
  return null;
}
