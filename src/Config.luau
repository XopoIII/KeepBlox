--!strict
--- The numbers the protocol runs on. Each one is measured against the harness scenarios
--- (tests/scenario/) and the ProfileStore baseline (tests/reference/BASELINE.md). A store can override
--- them for its own profiles, and the harness does, to explore them.

export type Config = {
	--> Seconds between an owner's writes. Every write renews the lease and saves the data if it
	--> changed, so this is also the most play a crash can lose.
	renew: number,
	--> Seconds a newcomer waits on a lease that does not move before it takes the key from a
	--> KeepBlox owner it believes dead. Must stay well above `renew`.
	death: number,
	--> Seconds after its first hand-over request that a newcomer takes a key from a ProfileStore owner,
	--> as ProfileStore itself does (its SESSION_STEAL).
	profileStoreSteal: number,
	--> A ProfileStore owner's LastUpdate this many seconds old means it is dead (its ASSUME_DEAD).
	profileStoreDead: number,
	--> Seconds a load may take in all before it fails with "timeout".
	loadTimeout: number,
	--> Seconds a single data store call may take before it counts as failed.
	callTimeout: number,
	--> Retry delays for a hand-over poll or a failed call: from `backoffMin`, doubling up to
	--> `backoffMax`.
	backoffMin: number,
	backoffMax: number,
	--> Bytes of data one key may write a minute; a larger profile saves less often (Roblox allows 4 MB).
	writeBytesPerMinute: number,
	--> Seconds BindToClose waits for releases before it gives up (Roblox allows 30).
	shutdownDeadline: number,
}

const Config = {}

Config.DEFAULT = table.freeze({
	renew = 15,
	death = 35,
	profileStoreSteal = 40,
	profileStoreDead = 630,
	loadTimeout = 120,
	callTimeout = 20,
	backoffMin = 1,
	backoffMax = 5,
	writeBytesPerMinute = 3 * 1024 * 1024,
	shutdownDeadline = 25,
} :: Config)

--> The defaults with `overrides` applied. Refuses a death time that could mistake a slow owner for a
--> dead one.
function Config.resolve(overrides: { [string]: any }?): Config
	const config: Config = table.clone(Config.DEFAULT) :: any
	if overrides then
		for key, value in overrides do
			assert((Config.DEFAULT :: any)[key] ~= nil, `KeepBlox: unknown setting "{key}"`)
			assert(type(value) == "number" and value > 0, `KeepBlox: setting "{key}" must be a positive number`)
			const target: any = config
			target[key] = value
		end
	end
	assert(config.death >= 2 * config.renew, "KeepBlox: death must be at least twice renew")
	assert(config.backoffMin <= config.backoffMax, "KeepBlox: backoffMin must not exceed backoffMax")
	return config
end

return Config
