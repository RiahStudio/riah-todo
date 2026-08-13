// Riah To-Do — the tools an agent uses to change today’s list.
//
// It writes the same file the note and the board use, so a change lands wherever
// you are looking within a second or two — and it works whether or not anything
// else is running.
//
// Register it with any MCP client, from this folder:
//   node bin/todo-mcp-server.mjs

import { MAX_ITEMS, ops, readPriorities, storePath } from "../lib/store.mjs";

// Only the MCP server needs dependencies. The list, the note and the board have
// none, so a missing install is worth an answer rather than a stack trace.
let McpServer;
let StdioServerTransport;
let z;
try {
  ({ McpServer } = await import("@modelcontextprotocol/sdk/server/mcp.js"));
  ({ StdioServerTransport } = await import("@modelcontextprotocol/sdk/server/stdio.js"));
  ({ z } = await import("zod"));
} catch (error) {
  process.stderr.write(
    "Riah To-Do's tools need their dependencies. Run \"npm install\" in the Riah To-Do folder.\n"
    + `(${error instanceof Error ? error.message : String(error)})\n`,
  );
  process.exit(1);
}

function toolResult(priorities) {
  const awake = priorities.items.filter((item) => !item.slept);
  const sleeping = priorities.items.filter((item) => item.slept);
  const lines = [];
  if (awake.length === 0 && sleeping.length === 0) {
    lines.push(`Today's Priorities (${priorities.date}) is empty.`);
  } else {
    lines.push(`Today's Priorities (${priorities.date}):`);
    for (const item of awake) {
      lines.push(`- [${item.completed ? "x" : " "}] ${item.label}`);
    }
    if (sleeping.length > 0) {
      lines.push("", `Sleeping (${sleeping.filter((item) => !item.parentId).length}):`);
      for (const item of sleeping.filter((item) => !item.parentId)) {
        lines.push(`- ${item.label}`);
      }
    }
  }
  return { content: [{ type: "text", text: lines.join("\n") }] };
}

function failed(error) {
  return {
    isError: true,
    content: [{ type: "text", text: error instanceof Error ? error.message : String(error) }],
  };
}

const server = new McpServer(
  { name: "riah-todo", version: "1.0.2" },
  {
    instructions:
      "Use these tools whenever the user asks to see or change today’s priorities, focus list, or to-do list. "
      + "They write the shared Riah To-Do file, so the change shows up on the tray note and the board within a couple of seconds. "
      + `The list holds at most ${MAX_ITEMS} items and labels are free-form — they do not have to match folder or project names.`,
  },
);

server.registerTool(
  "get_priorities",
  {
    title: "Get today's priorities",
    description: "Read the current list.",
    inputSchema: {},
    annotations: { readOnlyHint: true },
  },
  async () => {
    try {
      return toolResult(readPriorities());
    } catch (error) {
      return failed(error);
    }
  },
);

server.registerTool(
  "replace_priorities",
  {
    title: "Replace today's priorities",
    description:
      "Replace the whole list. Use when the user says to change, set, or make today’s list. "
      + "Items already on the list keep whether they were ticked off.",
    inputSchema: { labels: z.array(z.string().min(1).max(120)).max(MAX_ITEMS) },
    annotations: { destructiveHint: true, idempotentHint: true },
  },
  async ({ labels }) => {
    try {
      return toolResult(ops.replace(labels));
    } catch (error) {
      return failed(error);
    }
  },
);

server.registerTool(
  "add_priority",
  {
    title: "Add a priority",
    description: "Add one item to today's list.",
    inputSchema: { label: z.string().min(1).max(120) },
  },
  async ({ label }) => {
    try {
      return toolResult(ops.add(label));
    } catch (error) {
      return failed(error);
    }
  },
);

server.registerTool(
  "set_priority_completed",
  {
    title: "Complete or reopen a priority",
    description: "Tick a named item off today's list, or put it back.",
    inputSchema: {
      label: z.string().min(1).max(120),
      completed: z.boolean().default(true),
    },
    annotations: { idempotentHint: true },
  },
  async ({ label, completed }) => {
    try {
      return toolResult(ops.setCompleted(label, completed));
    } catch (error) {
      return failed(error);
    }
  },
);

server.registerTool(
  "remove_priority",
  {
    title: "Remove a priority",
    description: "Take one named item off today's list without completing it.",
    inputSchema: { label: z.string().min(1).max(120) },
    annotations: { destructiveHint: true, idempotentHint: true },
  },
  async ({ label }) => {
    try {
      return toolResult(ops.removeByLabel(label));
    } catch (error) {
      return failed(error);
    }
  },
);

server.registerTool(
  "sleep_priority",
  {
    title: "Sleep a priority",
    description:
      "Hide one named item from today's list without completing or removing it. Wake it later with wake_priority.",
    inputSchema: { label: z.string().min(1).max(120) },
    annotations: { idempotentHint: true },
  },
  async ({ label }) => {
    try {
      return toolResult(ops.setSleptByLabel(label, true));
    } catch (error) {
      return failed(error);
    }
  },
);

server.registerTool(
  "wake_priority",
  {
    title: "Wake a sleeping priority",
    description: "Put a sleeping item back on today's list.",
    inputSchema: { label: z.string().min(1).max(120) },
    annotations: { idempotentHint: true },
  },
  async ({ label }) => {
    try {
      return toolResult(ops.setSleptByLabel(label, false));
    } catch (error) {
      return failed(error);
    }
  },
);

process.stderr.write(`riah-todo mcp: ${storePath()}\n`);
await server.connect(new StdioServerTransport());
