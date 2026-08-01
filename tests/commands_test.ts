import { assert, assertEquals } from "@std/assert";
import { availableCommands, type Command, commandOptions } from "../src/ui/commands.ts";

function commands(): Command[] {
  return [
    { label: "New Session…", shortcut: "Alt+N", run: () => {} },
    { label: "Close Session", shortcut: "Alt+W", enabled: false, run: () => {} },
    { label: "Refresh VM List", run: () => {} },
  ];
}

Deno.test("a command that makes no sense right now never reaches the list", () => {
  assertEquals(
    availableCommands(commands()).map((command) => command.label),
    ["New Session…", "Refresh VM List"],
  );
});

Deno.test("the palette shows each command's shortcut, so using it teaches the chord", () => {
  const options = commandOptions(availableCommands(commands()));
  assertEquals(options[0], { label: "New Session…", detail: "Alt+N" });
  // A command with no chord is still offered; it just has nothing to teach.
  assertEquals(options[1], { label: "Refresh VM List", detail: undefined });
});

Deno.test("choosing by index runs the command that was shown at it", () => {
  const ran: string[] = [];
  const list = availableCommands([
    { label: "First", enabled: false, run: () => void ran.push("First") },
    { label: "Second", run: () => void ran.push("Second") },
    { label: "Third", run: () => void ran.push("Third") },
  ]);
  const options = commandOptions(list);
  const index = options.findIndex((option) => option.label === "Third");
  assert(index >= 0);
  list[index].run();
  assertEquals(ran, ["Third"]);
});
