// omp hook -> zzz.notch. Symlink into ~/.omp/agent/hooks/post/.
// One mascot per omp process (same id): session open -> "idle" (dozes off
// after a while), agent working -> "run" with the current tool call as
// detail, `ask` pending -> "wait", agent finished -> "ok" (pops up, mascot
// celebrates) then back to "idle", session closed -> cleared. UI sessions
// only, so subagents stay silent.
import * as path from "node:path";
import type { HookAPI } from "@oh-my-pi/pi-coding-agent/extensibility/hooks";

const ZZZ = process.env.ZZZ_BIN ?? path.join(process.env.HOME ?? "", ".local/bin/zzz");
const id = `omp-${process.pid}`;
/// Tool calls can come in bursts; send at most one detail update per interval.
const DETAIL_INTERVAL_MS = 800;

type Status = "run" | "wait" | "ok" | "idle";

/// "bash: Building and installing" — the tool's intent if it gave one,
/// else its most telling argument.
function describe(tool: string, input: unknown): string {
	const args = (input ?? {}) as Record<string, unknown>;
	const pick = ["i", "command", "path", "pattern", "query", "url"].map(k => args[k]).find(v => typeof v === "string");
	const text = typeof pick === "string" ? pick.replace(/\s+/g, " ").trim() : "";
	const line = text ? `${tool}: ${text}` : tool;
	return line.length > 120 ? `${line.slice(0, 119)}…` : line;
}

export default function (pi: HookAPI): void {
	const zzz = (args: string[]) => pi.exec(ZZZ, args).catch(() => undefined);
	const notify = (cwd: string, body: string, status: Status, detail?: string) =>
		zzz([
			"notify", path.basename(cwd), body,
			"--source", "omp", "--status", status, "--symbol", "sparkles",
			"--app", process.env.__CFBundleIdentifier ?? "",
			"--id", id,
			...(detail ? ["--detail", detail] : []),
		]);

	let pendingDetail: { cwd: string; detail: string } | undefined;
	let timer: NodeJS.Timeout | undefined;
	const flushDetail = () => {
		timer = undefined;
		if (pendingDetail) void notify(pendingDetail.cwd, "Working", "run", pendingDetail.detail);
		pendingDetail = undefined;
	};
	const dropDetail = () => {
		pendingDetail = undefined;
		clearTimeout(timer);
		timer = undefined;
	};

	pi.on("agent_start", async (_event, ctx) => {
		if (ctx.hasUI) void notify(ctx.cwd, "Working", "run");
	});

	pi.on("tool_call", async (event, ctx) => {
		if (!ctx.hasUI) return;
		if (event.toolName === "ask") {
			dropDetail();
			void notify(ctx.cwd, "Waiting for your answer", "wait");
			return;
		}
		pendingDetail = { cwd: ctx.cwd, detail: describe(event.toolName, event.input) };
		timer ??= setTimeout(flushDetail, DETAIL_INTERVAL_MS);
	});

	pi.on("tool_result", async (event, ctx) => {
		if (ctx.hasUI && event.toolName === "ask") void notify(ctx.cwd, "Working", "run");
	});

	pi.on("session_start", async (_event, ctx) => {
		if (ctx.hasUI) void notify(ctx.cwd, "Idle", "idle");
	});

	pi.on("agent_end", async (_event, ctx) => {
		if (!ctx.hasUI) return;
		dropDetail();
		void notify(ctx.cwd, "Done", "ok").then(() => notify(ctx.cwd, "Idle", "idle"));
	});

	pi.on("session_shutdown", async () => {
		dropDetail();
		await zzz(["clear", "--id", id]);
	});
}
