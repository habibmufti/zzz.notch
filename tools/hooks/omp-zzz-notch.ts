// omp hook -> zzz.notch. Symlink into ~/.omp/agent/hooks/post/.
// One mascot per omp process (same id): session open -> "idle" (dozes off
// after a while), agent working -> "run" with the current tool call as
// detail and a mascot activity, `ask` -> "wait" and the question goes to the
// notch (answer there, or in the terminal once the notch times out), agent
// finished -> "ok" then back to "idle", session closed -> cleared.
// Subagents (sessions without UI in the same process) don't get a mascot of
// their own; they show up as a badge count on the main one.
import * as path from "node:path";
import type { HookAPI } from "@oh-my-pi/pi-coding-agent/extensibility/hooks";

const ZZZ = process.env.ZZZ_BIN ?? path.join(process.env.HOME ?? "", ".local/bin/zzz");
const id = `omp-${process.pid}`;
/// Tool calls can come in bursts; send at most one detail update per interval.
const DETAIL_INTERVAL_MS = 800;
/// How long the notch gets to answer an `ask` before the terminal prompt shows.
const ASK_TIMEOUT_S = 120;

type Status = "run" | "wait" | "ok" | "idle";
type Activity = "type" | "search" | "build" | "push" | "read";

/// The main session's last state, shared with subagent sessions of the same
/// process (each session loads this hook separately).
interface Shared {
	cwd?: string;
	/// omp's session title, shown next to the project name.
	title?: string;
	status: Status;
	body: string;
	agents: number;
}
const shared: Shared = ((globalThis as Record<string, unknown>).__zzzNotch ??= {
	status: "idle",
	body: "Idle",
	agents: 0,
}) as Shared;

function oneLine(text: string, max: number): string {
	const line = text.replace(/[`*_#>]/g, "").replace(/\s+/g, " ").trim();
	return line.length > max ? `${line.slice(0, max - 1)}…` : line;
}

/// The session title omp generated, if this omp exposes one.
function sessionTitle(ctx: unknown): string | undefined {
	if (!ctx || typeof ctx !== "object" || !("sessionManager" in ctx)) return undefined;
	const manager = ctx.sessionManager;
	if (!manager || typeof manager !== "object" || !("getSessionName" in manager)) return undefined;
	const get = manager.getSessionName;
	const name = typeof get === "function" ? get.call(manager) : undefined;
	return typeof name === "string" && name.trim() ? oneLine(name, 60) : undefined;
}

/// First sentence of the agent's final reply: what got done.
function finalSummary(event: unknown): string | undefined {
	if (!event || typeof event !== "object" || !("messages" in event) || !Array.isArray(event.messages)) return undefined;
	for (const message of [...event.messages].reverse()) {
		if (!message || typeof message !== "object" || !("role" in message) || message.role !== "assistant") continue;
		const content = "content" in message ? message.content : undefined;
		const text = typeof content === "string"
			? content
			: Array.isArray(content)
				? content.map(part => (part && typeof part === "object" && "text" in part && typeof part.text === "string" ? part.text : "")).join(" ")
				: "";
		const first = text.trim().split(/(?<=[.!?])\s|\n/)[0] ?? "";
		if (first.trim()) return oneLine(first, 140);
	}
	return undefined;
}

function argsOf(input: unknown): Record<string, unknown> {
	return (input ?? {}) as Record<string, unknown>;
}

/// "bash: Building and installing": the tool's intent if it gave one,
/// else its most telling argument.
function describe(tool: string, input: unknown): string {
	const args = argsOf(input);
	const pick = ["i", "command", "path", "pattern", "query", "url"].map(k => args[k]).find(v => typeof v === "string");
	const text = typeof pick === "string" ? pick.replace(/\s+/g, " ").trim() : "";
	const line = text ? `${tool}: ${text}` : tool;
	return line.length > 120 ? `${line.slice(0, 119)}…` : line;
}

function activityOf(tool: string, input: unknown): Activity {
	const command = String(argsOf(input).command ?? "");
	if (/\bgit\s+push\b|\bgh\s+(pr\s+create|release)\b/.test(command)) return "push";
	if (/\b(build|make|cargo|xcodebuild|swiftc?|tsc|bun\s+(run|test)|npm\s+(run|test)|pytest|go\s+(build|test)|gh\s+run\s+watch)\b/.test(command)) return "build";
	if (["grep", "glob", "find", "web_search", "lsp"].includes(tool) || /\b(rg|grep|fd|find)\b/.test(command)) return "search";
	if (tool === "read") return "read";
	return "type";
}

function strip(html: string): string {
	return html.replace(/<[^>]*>/g, " ").replace(/&nbsp;/g, " ").replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/\s+/g, " ").trim();
}

interface NotchQuestion {
	question: string;
	name: string;
	options: { value: string; label: string }[];
	multiple: boolean;
}

/// The notch handles one-question forms: a single radio or checkbox group.
/// Anything else (text fields, several groups) stays in the terminal.
function questionOf(input: unknown): NotchQuestion | undefined {
	const html = String(argsOf(input).html ?? "");
	if (!html || /<(textarea|select)\b|type="(text|number|date|email|url)"/i.test(html)) return undefined;
	const inputs = [...html.matchAll(/<label[^>]*>\s*<input\b([^>]*)>([\s\S]*?)<\/label>/gi)];
	if (inputs.length < 1 || inputs.length > 6) return undefined;
	const attr = (a: string, k: string) => a.match(new RegExp(`${k}="([^"]*)"`, "i"))?.[1];
	const names = new Set(inputs.map(m => attr(m[1], "name")));
	const types = new Set(inputs.map(m => attr(m[1], "type")?.toLowerCase()));
	if (names.size !== 1 || types.size !== 1) return undefined;
	const type = [...types][0];
	if (type !== "radio" && type !== "checkbox") return undefined;
	const lead = html.match(/<legend[^>]*>([\s\S]*?)<\/legend>/i)?.[1] ?? html.match(/<p[^>]*>([\s\S]*?)<\/p>/i)?.[1] ?? "";
	const question = strip(lead) || "omp asks";
	return {
		question: question.length > 200 ? `${question.slice(0, 199)}…` : question,
		name: [...names][0] ?? "answer",
		options: inputs.map(m => ({ value: attr(m[1], "value") ?? strip(m[2]), label: strip(m[2]).slice(0, 60) })),
		multiple: type === "checkbox",
	};
}

export default function (pi: HookAPI): void {
	const zzz = (args: string[]) => pi.exec(ZZZ, args).catch(() => undefined);
	const send = (extra: string[] = []) =>
		shared.cwd
			? zzz([
					// The session's own title says what it is about; the
					// project moves to the small label next to it.
					"notify", shared.title ?? path.basename(shared.cwd), shared.body,
					"--source", shared.title ? path.basename(shared.cwd) : "omp", "--status", shared.status, "--symbol", "sparkles",
					"--app", process.env.__CFBundleIdentifier ?? "",
					"--id", id, "--agents", String(shared.agents),
					...extra,
				])
			: Promise.resolve(undefined);
	const set = (cwd: string, body: string, status: Status, extra: string[] = [], ctx?: unknown) => {
		shared.cwd = cwd;
		shared.title = sessionTitle(ctx) ?? shared.title;
		shared.body = body;
		shared.status = status;
		return send(extra);
	};

	let pending: string[] | undefined;
	let timer: NodeJS.Timeout | undefined;
	const flush = () => {
		timer = undefined;
		if (pending && shared.status === "run") void send(pending);
		pending = undefined;
	};
	const dropPending = () => {
		pending = undefined;
		clearTimeout(timer);
		timer = undefined;
	};

	pi.on("before_agent_start", async (event, ctx) => {
		if (!ctx.hasUI) return;
		const raw = "prompt" in event ? event.prompt : "";
		const prompt = String(raw ?? "").replace(/\s+/g, " ").trim();
		void set(ctx.cwd, "Working", "run", prompt ? ["--prompt", prompt.slice(0, 160)] : [], ctx);
	});

	pi.on("agent_start", async (_event, ctx) => {
		if (ctx.hasUI) {
			if (shared.status !== "run") void set(ctx.cwd, "Working", "run");
		} else {
			shared.agents += 1;
			void send();
		}
	});

	pi.on("tool_call", async (event, ctx) => {
		if (!ctx.hasUI) return;
		if (event.toolName !== "ask") {
			pending = ["--detail", describe(event.toolName, event.input), "--activity", activityOf(event.toolName, event.input)];
			timer ??= setTimeout(flush, DETAIL_INTERVAL_MS);
			return;
		}
		dropPending();
		const q = questionOf(event.input);
		void set(ctx.cwd, q?.question ?? "Waiting for your answer", "wait");
		if (!q) return;
		const args = ["ask", q.question, "--id", id, "--timeout", String(ASK_TIMEOUT_S)];
		for (const o of q.options) args.push("--option", o.label);
		if (q.multiple) args.push("--multiple");
		const result = await pi.exec(ZZZ, args).catch(() => undefined);
		const picked = (result?.stdout ?? "").split("\n").map(s => s.trim()).filter(Boolean);
		if (picked.length === 0) return; // no answer (zzz ask prints nothing): the terminal prompt takes over
		const values = picked.map(label => q.options.find(o => o.label === label)?.value ?? label);
		void set(ctx.cwd, "Working", "run");
		return {
			block: true,
			reason: `The user answered in the notch (the form was not shown in the terminal): ${JSON.stringify({ [q.name]: q.multiple ? values : values[0] })}`,
		};
	});

	pi.on("tool_result", async (event, ctx) => {
		if (ctx.hasUI && event.toolName === "ask") void set(ctx.cwd, "Working", "run");
	});

	pi.on("session_start", async (_event, ctx) => {
		if (ctx.hasUI) void set(ctx.cwd, "Idle", "idle");
	});

	pi.on("agent_end", async (event, ctx) => {
		if (!ctx.hasUI) {
			shared.agents = Math.max(0, shared.agents - 1);
			void send();
			return;
		}
		dropPending();
		const summary = finalSummary(event) ?? "Done";
		void set(ctx.cwd, summary, "ok", [], ctx).then(() => set(ctx.cwd, "Idle", "idle", [], ctx));
	});

	pi.on("session_shutdown", async (_event, ctx) => {
		if (!ctx.hasUI) return;
		dropPending();
		await zzz(["clear", "--id", id]);
	});
}
