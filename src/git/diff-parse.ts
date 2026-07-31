/**
 * A unified diff broken into displayable rows, plus the totals the pane header
 * shows. Parsed once per distinct diff text rather than on every redraw.
 */

export type DiffRowKind = "file" | "hunk" | "addition" | "deletion" | "context" | "meta";

export interface DiffRow {
  kind: DiffRowKind;
  /**
   * The line's number in the new file (additions, context) or the old file
   * (deletions). A single column leaves room for code in a narrow sidebar.
   */
  number: number | null;
  text: string;
  /** The function/context suffix git puts after a hunk header, if any. */
  detail: string | null;
}

export interface ParsedDiff {
  rows: DiffRow[];
  additions: number;
  deletions: number;
  /** Gutter width sized to the widest line number in this diff. */
  gutterWidth: number;
}

export function parseDiff(diff: string, includeFileHeaders: boolean): ParsedDiff {
  const parsed: ParsedDiff = { rows: [], additions: 0, deletions: 0, gutterWidth: 3 };
  const lines = diff.split("\n");
  if (lines.length > 0 && lines[lines.length - 1] === "") lines.pop(); // trailing newline

  let oldNumber = 0;
  let newNumber = 0;
  let widest = 0;
  // Once a hunk starts, every line is content and is classified by its first
  // character alone. Outside a hunk the same text is a header. Without this,
  // deleting a line that begins with "-- " — a SQL comment, a signature
  // delimiter — arrives as "--- …", gets taken for a file header, and vanishes
  // from both the pane and the deletion count.
  let inHunk = false;

  for (const line of lines) {
    if (line.startsWith("diff --git ")) {
      oldNumber = 0;
      newNumber = 0;
      inHunk = false;
      // For a single-file diff the pane header already names the file.
      if (includeFileHeaders) {
        parsed.rows.push({ kind: "file", number: null, text: pathFromHeader(line), detail: null });
      }
    } else if (line.startsWith("@@")) {
      // Always a real header: content lines always carry a "+", "-" or " "
      // prefix, so a bare "@@" can only start a hunk.
      inHunk = true;
      const header = splitHunkHeader(line);
      const starts = hunkStarts(header.range);
      if (starts) {
        oldNumber = starts.old;
        newNumber = starts.new;
      }
      parsed.rows.push({
        kind: "hunk",
        number: null,
        text: header.range,
        detail: header.context,
      });
    } else if (
      !inHunk &&
      (line.startsWith("index ") || line.startsWith("--- ") || line.startsWith("+++ "))
    ) {
      continue; // Blob hashes and a/ b/ paths add nothing to read.
    } else if (line.startsWith("+")) {
      parsed.rows.push({
        kind: "addition",
        number: newNumber,
        text: display(line.slice(1)),
        detail: null,
      });
      parsed.additions += 1;
      widest = Math.max(widest, newNumber);
      newNumber += 1;
    } else if (line.startsWith("-")) {
      parsed.rows.push({
        kind: "deletion",
        number: oldNumber,
        text: display(line.slice(1)),
        detail: null,
      });
      parsed.deletions += 1;
      widest = Math.max(widest, oldNumber);
      oldNumber += 1;
    } else if (line.startsWith(" ") || line === "") {
      parsed.rows.push({
        kind: "context",
        number: newNumber,
        text: display(line.slice(1)),
        detail: null,
      });
      widest = Math.max(widest, newNumber);
      oldNumber += 1;
      newNumber += 1;
    } else {
      // "new file mode", "Binary files … differ", "\ No newline …".
      parsed.rows.push({ kind: "meta", number: null, text: line, detail: null });
    }
  }

  parsed.gutterWidth = Math.max(2, String(widest).length);
  return parsed;
}

/** "diff --git a/x b/x" → "x" (the post-rename path). */
function pathFromHeader(line: string): string {
  const separator = line.indexOf(" b/");
  if (separator !== -1) return line.slice(separator + " b/".length);
  return line.slice("diff --git ".length);
}

/**
 * Splits "@@ -1,7 +1,9 @@ func foo()" into the range and its trailing context,
 * which is usually the enclosing function — worth showing.
 */
function splitHunkHeader(line: string): { range: string; context: string | null } {
  const close = line.indexOf("@@", 2);
  if (close === -1) return { range: line, context: null };
  const range = line.slice(0, close + 2);
  const context = line.slice(close + 2).trim();
  return { range, context: context || null };
}

/** First line number on each side of "@@ -12,7 +14,9 @@". */
function hunkStarts(range: string): { old: number; new: number } | null {
  const tokens = range.split(" ").filter((token) => token.length > 0);
  if (tokens.length < 3) return null;
  const old = startOfToken(tokens[1]);
  const next = startOfToken(tokens[2]);
  if (old === null || next === null) return null;
  return { old, new: next };
}

/** "-12,7" → 12. */
function startOfToken(token: string): number | null {
  const digits = token.slice(1).split(",")[0];
  if (!/^\d+$/.test(digits)) return null;
  return Number(digits);
}

/**
 * Tabs render at unpredictable widths, so expand them to keep the monospaced
 * grid honest; CRs from Windows files would show as boxes.
 */
function display(text: string): string {
  return text.replaceAll("\t", "    ").replaceAll("\r", "");
}
