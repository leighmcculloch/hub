/**
 * The list a dropdown opens.
 *
 * Every dropdown in the app opens one of these rather than only cycling
 * through its values, because cycling never shows you what the other options
 * are — and some of these lists (the model catalogue) run to hundreds of
 * entries. So the popup scrolls, and types to filter.
 */

import { Color, elideMiddle, fit, styled } from "../tui/ansi.ts";
import {
  type HitMap,
  panel,
  type Rect,
  row as listRow,
  scrollbar,
  scrollToShow,
  TextInput,
} from "../tui/widgets.ts";

export interface SelectOption {
  label: string;
  /** Shown dimmed after the label — a caption, not part of the value. */
  detail?: string;
}

/** Where the caret goes when the popup's filter has the keyboard. */
export interface CursorHint {
  x: number;
  y: number;
}

export class SelectPopup {
  private filter = new TextInput();
  private selection: number;
  private offset = 0;
  private hovered: string | null = null;
  /** The filtered options, kept from the last render so keys and clicks agree. */
  private visible: Array<{ option: SelectOption; index: number }> = [];
  private cursor: CursorHint | null = null;

  /**
   * `selected` is the option that is currently the value: it starts under the
   * keyboard and carries the ● marker, so opening the list shows you where you
   * already are.
   */
  constructor(
    readonly title: string,
    readonly options: SelectOption[],
    private selected: number,
    private onChoose: (index: number) => void,
  ) {
    this.selection = Math.max(0, selected);
  }

  /** Where the caret should sit, once this frame has been laid out. */
  cursorPosition(): CursorHint | null {
    return this.cursor;
  }

  render(cols: number, rows: number, hits: HitMap): { lines: string[]; rect: Rect } {
    const width = Math.min(66, Math.max(28, cols - 6));
    const filtered = this.filtered();
    // Tall enough for the list, but never taller than the terminal.
    const height = Math.min(Math.max(7, filtered.length + 5), rows - 2);
    const rect: Rect = {
      x: Math.floor((cols - width) / 2),
      y: Math.floor((rows - height) / 2),
      width,
      height,
    };
    const inner = width - 2;
    const originX = rect.x + 1;
    const originY = rect.y + 1;

    const body: string[] = [];
    hits.add({ x: originX, y: originY, width: inner, height: 1 }, "popup.filter");
    body.push(
      this.filter.render(inner, true, `Type to filter ${this.options.length} options…`, false),
    );
    this.cursor = { x: originX + this.filter.cursorOffset(inner), y: originY };

    const listHeight = height - 4;
    this.selection = Math.min(Math.max(0, this.selection), Math.max(0, filtered.length - 1));
    this.offset = scrollToShow(this.offset, this.selection, listHeight, filtered.length);
    const bar = scrollbar(this.offset, listHeight, filtered.length);

    for (let index = 0; index < listHeight; index += 1) {
      const entry = filtered[this.offset + index];
      if (!entry) {
        body.push(
          index === 0 && filtered.length === 0
            ? fit(
              ` ${styled("No option matches that filter.", { fg: Color.dimmer, bg: Color.panel })}`,
              inner,
              { bg: Color.panel },
            )
            : fit("", inner, { bg: Color.panel }),
        );
        continue;
      }
      const id = `popup.option:${this.offset + index}`;
      hits.add({ x: originX, y: originY + 1 + index, width: inner, height: 1 }, id);
      const active = this.offset + index === this.selection;
      const mark = entry.index === this.selected ? styled("● ", { fg: Color.accent }) : "  ";
      const label = elideMiddle(entry.option.label, Math.max(8, inner - 6));
      const detail = entry.option.detail
        ? ` ${styled(entry.option.detail, { fg: Color.dimmer })}`
        : "";
      body.push(
        fit(
          listRow(`${mark}${label}${detail}`, inner - 1, {
            selected: active,
            hovered: this.hovered === id,
            focused: true,
          }) + bar[index],
          inner,
          { bg: Color.panel },
        ),
      );
    }

    body.push(
      fit(
        ` ${styled("↑↓ move · Enter choose · Esc cancel", { fg: Color.dimmer, bg: Color.panel })}`,
        inner,
        { bg: Color.panel },
      ),
    );

    this.visible = filtered;
    return { lines: panel(width, height, this.title, body, { bg: Color.panel }), rect };
  }

  private filtered(): Array<{ option: SelectOption; index: number }> {
    const needle = this.filter.value.trim().toLowerCase();
    const all = this.options.map((option, index) => ({ option, index }));
    if (!needle) return all;
    return all.filter(({ option }) =>
      option.label.toLowerCase().includes(needle) ||
      (option.detail ?? "").toLowerCase().includes(needle)
    );
  }

  setHover(id: string | null): void {
    this.hovered = id;
  }

  /** Returns true when the popup should close. */
  key(event: { name: string; ctrl: boolean; alt: boolean; shift: boolean }): boolean {
    switch (event.name) {
      case "escape":
        return true;
      case "up":
        this.selection = Math.max(0, this.selection - 1);
        return false;
      case "down":
        this.selection = Math.min(this.visible.length - 1, this.selection + 1);
        return false;
      case "pageup":
        this.selection = Math.max(0, this.selection - 10);
        return false;
      case "pagedown":
        this.selection = Math.min(this.visible.length - 1, this.selection + 10);
        return false;
      case "home":
        // Home and End belong to the list here; the filter is short enough that
        // Ctrl+A / Ctrl+E cover its own ends.
        this.selection = 0;
        return false;
      case "end":
        this.selection = this.visible.length - 1;
        return false;
      case "enter": {
        const entry = this.visible[this.selection];
        if (entry) this.onChoose(entry.index);
        return true;
      }
      default:
        if (this.filter.handle(event)) {
          // A narrower list can leave the selection past its end.
          this.selection = 0;
          this.offset = 0;
        }
        return false;
    }
  }

  /** Returns true when the popup should close. */
  click(id: string): boolean {
    if (!id.startsWith("popup.option:")) return false;
    const entry = this.visible[Number(id.slice("popup.option:".length))];
    if (!entry) return false;
    this.onChoose(entry.index);
    return true;
  }

  scroll(delta: number): void {
    this.offset = Math.max(0, this.offset + delta);
  }
}
