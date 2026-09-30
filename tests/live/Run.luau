--!strict
--- Runs a live check in the background (see tests/live/README.md). The lines go to the output and to
--- `log.Value`; the last one starts with "DONE".
const Conformance = require("./Conformance")
const Env = require("./Env")
const Features = require("./Features")
const Scenarios = require("./Scenarios")
const Stress = require("./Stress")

export type Modules = { KeepBlox: any, RobloxServices: any, ProfileStore: any }

const Run = {}

type Step = { name: string, run: () -> () }

const function steps(modules: Modules, which: string): { Step }
	if which == "stress" then
		return { {
			name = "stress",
			run = function()
				Stress.run({})
			end,
		} }
	end
	const all: { Step } = {
		{ name = "roundtrip", run = Scenarios.roundtrip },
		{ name = "handover", run = Scenarios.handover },
		{ name = "race", run = Scenarios.race },
		{ name = "crash", run = Scenarios.crash },
		{ name = "shutdown", run = Scenarios.shutdown },
		{ name = "messages", run = Features.messages },
		{ name = "receipts", run = Features.receipts },
		{ name = "versions", run = Features.versions },
		{ name = "migrations", run = Features.migrations },
		{ name = "trade", run = Features.trade },
		{ name = "compress", run = Features.compress },
		{
			name = "profilestore",
			run = function()
				Features.profileStore(modules.ProfileStore)
			end,
		},
		{ name = "encoding", run = Conformance.encoding },
		{ name = "versions (engine)", run = Conformance.versions },
		{ name = "messaging (engine)", run = Conformance.messaging },
		{ name = "ordered (engine)", run = Conformance.ordered },
	}
	for _ = 1, 2 do -- more samples of the two timings that matter most
		table.insert(all, { name = "handover again", run = Scenarios.handover })
		table.insert(all, { name = "crash again", run = Scenarios.crash })
	end
	return all
end

--> Starts `which` ("functional" or "stress"); returns the run's id, which names its data stores.
function Run.start(modules: Modules, log: StringValue, which: string): string
	Env.init(modules.KeepBlox, modules.RobloxServices, log)
	task.spawn(function()
		Env.log(`RUN {Env.run} ({which}), data stores {Env.store}*`)
		for _, step in steps(modules, which) do
			Env.log(`== {step.name}`)
			const began = os.clock()
			local done = false
			task.spawn(function()
				local problem: string? = nil
				xpcall(step.run, function(message: any)
					problem = debug.traceback(tostring(message))
				end)
				if problem then
					Env.check(`{step.name}: no error`, false, problem)
				end
				done = true
			end)
			const finished = Env.waitFor(if which == "stress" then 1200 else 240, function(): boolean
				return done
			end)
			if not finished then
				Env.check(`{step.name}: finished in time`, false)
			end
			Env.closeOpened()
			Env.log(`-- {step.name}: {string.format("%.1f", os.clock() - began)} s`)
		end
		const failures = if Env.fail > 0 then `: {table.concat(Env.failures, "; ")}` else ""
		Env.log(`DONE pass {Env.pass} fail {Env.fail}{failures}`)
	end)
	return Env.run
end

return Run
