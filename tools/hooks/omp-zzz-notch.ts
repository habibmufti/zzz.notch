// omp hook -> zzz.notch. Copy or symlink into ~/.omp/agent/hooks/post/.
// `ask` tool call -> yellow "waiting" event that stays until answered;
// agent_end -> green "done" event replacing it. One live event per omp
// process; headless sessions (subagents) stay silent.
import * as path from "node:path";
import type { HookAPI } from "@oh-my-pi/pi-coding-agent/extensibility/hooks";

const ZZZ = process.env.ZZZ_BIN ?? path.join(process.env.HOME ?? "", ".local/bin/zzz");
const id = `omp-${process.pid}`;

export default function (pi: HookAPI): void {
	const notify = (cwd: string, body: string, status: "ok" | "wait", duration: number) =>
		pi
			.exec(ZZZ, [
				"notify", path.basename(cwd), body,
				"--source", "omp", "--status", status, "--symbol", "sparkles",
				"--app", process.env.__CFBundleIdentifier ?? "",
				"--id", id, "--duration", String(duration),
			])
			.catch(() => undefined);

	pi.on("tool_call", async (event, ctx) => {
		if (!ctx.hasUI || event.toolName !== "ask") return;
		await notify(ctx.cwd, "Waiting for your answer", "wait", 900);
	});

	pi.on("agent_end", async (_event, ctx) => {
		if (!ctx.hasUI) return;
		await notify(ctx.cwd, "Done", "ok", 8);
	});
}
