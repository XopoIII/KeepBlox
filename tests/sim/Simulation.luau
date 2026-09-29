--!strict
--- Many virtual servers, simulated players and faults, one seed: the stage every scenario runs on.
---
---     const sim = Simulation.new(seed, ProfileStoreAdapter)
---     const a, b = sim:server("A"), sim:server("B")
---     a:join("u_1")
---     sim:run(30)
---     a:leave("u_1"); b:join("u_1")
---     sim:run(120)
---     const report = sim:finish()
---
--- A player plays one step a second (`data.n += 1`) while its session is active. `leave` releases the
--- session; `crash` stops the server where it stands; `shutdown` removes every player (as the engine
--- does before closing), then runs the BindToClose callbacks in parallel and kills the server when
--- they finish or 30 s pass. Everything reports to the ledger.
const Adapter = require("./Adapter")
const Ledger = require("./Ledger")
const RobloxEnv = require("./RobloxEnv")
const Scheduler = require("@fakes/Scheduler")
const World = require("@fakes/World")

export type Shutdown = { server: string, finished: boolean, seconds: number }

export type Report = {
	violations: { Ledger.Violation },
	metrics: Ledger.Metrics,
	shutdowns: { Shutdown },
	--> Errors thrown in any simulated thread (the library's or the players').
	failures: { Scheduler.Failure },
}

export type ServerHandle = {
	read name: string,
	read server: World.Server,
	read env: RobloxEnv.Env,
	join: (self: ServerHandle, key: string) -> (),
	leave: (self: ServerHandle, key: string) -> (),
	--> Changes the live data of `key`'s open session on this server, as game code would.
	edit: (self: ServerHandle, key: string, change: (data: any) -> ()) -> (),
	crash: (self: ServerHandle) -> (),
	shutdown: (self: ServerHandle) -> (),
}

export type Simulation = {
	read world: World.World,
	read scheduler: Scheduler.Scheduler,
	read ledger: Ledger.Ledger,
	--> A new server. `library` runs on it instead of the simulation's own, for mixed rollouts.
	server: (self: Simulation, name: string, options: World.ServerOptions?, library: Adapter.Adapter?) -> ServerHandle,
	run: (self: Simulation, seconds: number) -> (),
	finish: (self: Simulation) -> Report,
}

const SHUTDOWN_DEADLINE = 30
const STEP_SECONDS = 1

const Simulation = {}

function Simulation.new(seed: number, adapter: Adapter.Adapter): Simulation
	const world = World.new(seed)
	const scheduler = world.scheduler
	const jobs: { [string]: string } = {}
	const jobOf = function(name: string): string
		return jobs[name] or `job-{name}`
	end
	const ledger = Ledger.new(scheduler, jobOf)
	const shutdowns: { Shutdown } = {}
	world.backend:observe(function(event)
		if event.store == adapter.store then
			Ledger.checkWrite(ledger, scheduler, jobOf, event, adapter.format)
		end
	end)

	const sim: Simulation = {
		world = world,
		scheduler = scheduler,
		ledger = ledger,

		server = function(
			_: Simulation,
			name: string,
			options: World.ServerOptions?,
			libraryAdapter: Adapter.Adapter?
		): ServerHandle
			const chosen = libraryAdapter or adapter
			const serverOptions: World.ServerOptions = { name = name }
			if options then
				serverOptions.players = options.players
				serverOptions.skew = options.skew
				serverOptions.drift = options.drift
				serverOptions.placeId = options.placeId
				serverOptions.jobId = options.jobId
			end
			const server = world:server(serverOptions)
			jobs[name] = server.services.jobId
			const env = RobloxEnv.new(world, server)
			local library: Adapter.Library? = nil
			const present: { [string]: boolean } = {}
			const sessions: { [string]: Adapter.Session } = {}
			local alive = true
			local opens = 0

			scheduler:spawn(function()
				library = chosen.boot(env)
			end, name)

			const function play(key: string)
				while library == nil do
					server.services.clock.wait(STEP_SECONDS / 10)
				end
				const lib = library :: Adapter.Library
				ledger:opening(key, name)
				local ended = false
				const session = lib.open(key, {
					acked = function(saved: Adapter.Data)
						ledger:acked(key, saved.p)
					end,
					ended = function()
						if not ended then
							ended = true
							ledger:ended(key, name)
						end
					end,
					cancelled = function(): boolean
						return not present[key]
					end,
				})
				if session == nil then
					ledger:openFailed(key, name)
					return
				end
				ledger:opened(key, name, table.clone(session.data.p))
				sessions[key] = session
				opens += 1
				const tag = `{name}#{opens}`
				while present[key] and session.isActive() do
					server.services.clock.wait(STEP_SECONDS)
					if present[key] and session.isActive() then
						const progress = session.data.p
						progress[tag] = (progress[tag] or 0) + 1
						ledger:mutated(key, tag, progress[tag])
					end
				end
				if session.isActive() then
					session.release()
				end
			end

			const handle: ServerHandle = {
				name = name,
				server = server,
				env = env,
				join = function(_: ServerHandle, key: string)
					assert(alive, `server {name} is down`)
					present[key] = true
					scheduler:spawn(play, name, key)
				end,
				leave = function(_: ServerHandle, key: string)
					present[key] = nil
				end,
				edit = function(_: ServerHandle, key: string, change: (data: any) -> ())
					const session = sessions[key]
					assert(session, `no session for {key} on {name}`)
					change(session.data)
				end,
				crash = function(_: ServerHandle)
					alive = false
					table.clear(present)
					server:crash()
					ledger:crashed(name)
				end,
				shutdown = function(self: ServerHandle)
					alive = false
					table.clear(present)
					scheduler:spawn(function()
						const started = scheduler.now
						local running = 0
						for _, callback in server.closing do
							running += 1
							scheduler:resume(function()
								callback()
								running -= 1
							end, name)
						end
						while running > 0 and scheduler.now - started < SHUTDOWN_DEADLINE do
							scheduler:wait(STEP_SECONDS / 10)
						end
						table.insert(shutdowns, {
							server = name,
							finished = running == 0,
							seconds = scheduler.now - started,
						})
						server:crash()
						ledger:crashed(self.name)
					end, `{name}#shutdown`)
				end,
			}
			return handle
		end,

		run = function(_: Simulation, seconds: number)
			scheduler:run(scheduler.now + seconds)
		end,

		finish = function(_: Simulation): Report
			ledger:finish(world.backend, adapter.store, adapter.format, world)
			return {
				violations = ledger.violations,
				metrics = ledger.metrics,
				shutdowns = shutdowns,
				failures = scheduler.failures,
			}
		end,
	}
	return sim
end

return Simulation
