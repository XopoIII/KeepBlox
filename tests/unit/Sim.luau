--!strict
--- Helpers for specs that drive the fakes: run a body as a server thread and fail loudly on any error
--- a simulated thread threw, so a spec never passes over a thread that died quietly.
const Scheduler = require("@fakes/Scheduler")

const Sim = {}

--> Runs `fn` as a thread of `group` until the scheduler is idle (or `untilTime`), then throws the first
--> failure any thread recorded during the run.
function Sim.run(scheduler: Scheduler.Scheduler, group: string, fn: () -> (), untilTime: number?)
	const before = #scheduler.failures
	scheduler:spawn(fn, group)
	scheduler:run(untilTime)
	const failure = scheduler.failures[before + 1]
	if failure then
		error(`thread {failure.thread} of {failure.group} failed: {failure.message}`, 2)
	end
end

--> Runs `fn` as a thread and returns the error it threw, or nil when it returned normally.
function Sim.catch(scheduler: Scheduler.Scheduler, group: string, fn: () -> ()): string?
	local caught: string? = nil
	Sim.run(scheduler, group, function()
		const ok, message = pcall(fn)
		if not ok then
			caught = tostring(message)
		end
	end)
	return caught
end

return Sim
