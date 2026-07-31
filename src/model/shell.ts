/** Single-quote for a POSIX shell, escaping embedded single quotes. */
export function shellQuote(argument: string): string {
  return `'${argument.replaceAll("'", "'\\''")}'`;
}
