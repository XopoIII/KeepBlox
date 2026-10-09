--!strict
--- The rig of the specs on cancelled callers (tests/unit/Cancelled.luau, CancelledErrors.luau): one
--- server, one store, every committed write of the key on record, and a codec that can be broken.
const Codec = require("@fakes/Codec")
const KeepBlox = require("@keepblox")
const World = require("@fakes/World")

const CancelRig = {}

--> Seconds between renewals in the rig's store.
CancelRig.RENEW = 20

export type Rig = {
	world: World.World,
	server: World.Server,
	store: KeepBlox.Store<any>,
	errors: { string },
	--> Every committed write of the key, in order: the coins stored, and whether the key stayed held.
	log: { { coins: number, held: boolean } },
	--> Breaks the codec: compressing throws from then on (a compressing store only).
	codec: { broken: boolean },
	--> Starts `profile:save()` in a thread of its own, which runs at once up to its first yield.
	save: (profile: any, name: string) -> thread,
	answers: { [string]: boolean },
}

--> A world with one server "A" and its store "Profiles"; `options` are added to the store's.
function CancelRig.new(options: { [string]: any }?): Rig
	const world = World.new(1)
	const server = world:server({ name = "A" })
	const real = Codec.new()
	const codec = { broken = false }
	const services = table.clone(server.services)
	const breakable = table.clone(real)
	breakable.compress = function(text: string): buffer
		if codec.broken then
			error("the codec is down", 0)
		end
		return real.compress(text)
	end
	services.codec = breakable
	const log: { { coins: number, held: boolean } } = {}
	world.backend:observe(function(event: any)
		const value = event.version.value
		const data = if typeof(value.Data.z) == "buffer" then real.decode(real.decompress(value.Data.z)) else value.Data
		table.insert(log, { coins = data.coins, held = value.MetaData.ActiveSession ~= nil })
	end)
	const settings: { [string]: any } =
		{ template = { coins = 0 }, config = { renew = CancelRig.RENEW }, services = services }
	for name, value in options or {} do
		settings[name] = value
	end
	const store = KeepBlox.store("Profiles", settings :: any)
	const errors: { string } = {}
	store.onError:connect(function(key: string, message: string)
		table.insert(errors, `{key}: {message}`)
	end)
	const answers: { [string]: boolean } = {}
	return {
		world = world,
		server = server,
		store = store,
		errors = errors,
		log = log,
		codec = codec,
		answers = answers,
		save = function(profile: any, name: string): thread
			local thread: thread? = nil
			world.scheduler:resume(function()
				thread = coroutine.running()
				answers[name] = profile:save()
			end)
			return thread :: thread
		end,
	}
end

--> The record of "u_1" as the store holds it now.
function CancelRig.stored(world: World.World): any
	return (world.backend:latest("Profiles/global", "u_1") :: any).value
end

return CancelRig
