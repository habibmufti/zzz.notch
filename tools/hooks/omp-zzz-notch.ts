// omp hook -> zzz.notch. Symlink into ~/.omp/agent/hooks/post/.
// One mascot per omp process (same id): session open -> "idle" (dozes off
// after a while), agent working -> "run", `ask` pending -> "wait", agent
// finished -> "ok" (pops up, mascot celebrates) then back to "idle",
// session closed -> cleared. UI sessions only, so subagents stay silent.
import * as path from "node:path";
import type { HookAPI } from "@oh-my-pi/pi-coding-agent/extensibility/hooks";

const ZZZ = process.env.ZZZ_BIN ?? path.join(process.env.HOME ?? "", ".local/bin/zzz");
const id = `omp-${process.pid}`;

export default function (pi: HookAPI): void {
	const zzz = (args: string[]) => pi.exec(ZZZ, args).catch(() => undefined);
	const notify = (cwd: string, body: string, status: "run" | "wait" | "ok" | "idle") =>
		zzz([
			"notify", path.basename(cwd), body,
			"--source", "omp", "--status", status, "--symbol", "sparkles",
			"--app", process.env.__CFBundleIdentifier ?? "",
			"--id", id,
		]);

	pi.on("agent_start", async (_event, ctx) => {
		if (ctx.hasUI) void notify(ctx.cwd, "Working", "run");
	});

	pi.on("tool_call", async (event, ctx) => {
		if (ctx.hasUI && event.toolName === "ask") void notify(ctx.cwd, "Waiting for your answer", "wait");
	});

	pi.on("tool_result", async (event, ctx) => {
		if (ctx.hasUI && event.toolName === "ask") void notify(ctx.cwd, "Working", "run");
	});

	pi.on("session_start", async (_event, ctx) => {
		if (ctx.hasUI) void notify(ctx.cwd, "Idle", "idle");
	});

	pi.on("agent_end", async (_event, ctx) => {
		if (!ctx.hasUI) return;
		void notify(ctx.cwd, "Done", "ok").then(() => notify(ctx.cwd, "Idle", "idle"));
	});

	pi.on("session_shutdown", async () => {
		await zzz(["clear", "--id", id]);
	});
}
