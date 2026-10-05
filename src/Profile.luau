--!strict
--- The profile the game holds: its data, and what it may ask of the session behind it.
---
---     profile.Data.coins += 10       -- change freely; the library notices and saves
---     profile:save()                  -- save now; true once it is stored
---     profile:release()               -- final save, then the lock is let go
---     profile.onEnded:connect(function(reason) ... end)
---
--- When the session ends, for any reason, `Data` is frozen (deeply, with `table.freeze`). Code that
--- still writes to it fails loudly instead of changing a copy nobody will save. That matters most when
--- the session was lost to another server: trades and purchases must stop on the stale copy
--- (guarantee 6).
const Record = require("./Record")
const Signal = require("./Signal")

export type EndReason = "released" | "handedOver" | "lost" | "shutdown"

--> `T` is the shape of the data: `Profile` alone is a profile of `any`, as it always was, and a game
--> that types its data writes `Profile<PlayerData>`.
export type Profile<T = any> = {
	--> The live data. Change it in place; it is saved when it changed.
	Data: T,
	--> The data as last stored, a copy. Receipts wait for this to hold their id.
	LastSavedData: T,
	UserIds: { number },
	RobloxMetaData: { [string]: any },
	key: string,
	--> How many sessions this key has had, this one included.
	loadCount: number,
	--> When the profile was first created, in Unix seconds (ProfileCreateTime).
	createdAt: number,
	--> When this record was last written before this session took it, in Unix seconds (the previous
	--> session's LastUpdate). 0 for a profile that had never been stored.
	lastSavedAt: number,
	--> Fires right before each save takes its snapshot: the last chance to write into `Data`. A heartbeat
	--> snapshot is one too, so it fires every `heartbeat` seconds (4 by default). `final` is true for the
	--> release, with the reason it ends. A listener must not yield, or its later writes miss the save.
	onSaving: Signal.Signal<boolean, EndReason?>,
	--> Fires with a copy of the stored data after every successful save.
	onSaved: Signal.Signal<T>,
	--> Fires once, when the session ends. `Data` is frozen by then.
	onEnded: Signal.Signal<EndReason>,
	isActive: (self: Profile<T>) -> boolean,
	--> Saves now and yields until it is stored: true, or false if it could not be.
	save: (self: Profile<T>) -> boolean,
	--> Ends the session: a final save, then the lock is released. Yields until done.
	release: (self: Profile<T>) -> (),
	--> Handles offline messages sent to this key (`store:message`). Each message goes to one handler:
	--> the handlers in turn, until one calls `processed()` after changing `Data`. The message leaves
	--> the queue in the same save that stores that change, so it is handled exactly once.
	onMessage: (self: Profile<T>, handler: (message: any, processed: () -> ()) -> ()) -> (),
	addUserId: (self: Profile<T>, userId: number) -> (),
	removeUserId: (self: Profile<T>, userId: number) -> (),
}

--> What the session behind a profile provides.
export type Backing = {
	isActive: () -> boolean,
	save: () -> boolean,
	release: () -> (),
	handle: (handler: (message: any, processed: () -> ()) -> ()) -> (),
}

const Profile = {}

--> Freezes `value` and everything in it, so no write to it goes unnoticed.
function Profile.freeze(value: any)
	if type(value) == "table" and not table.isfrozen(value) then
		table.freeze(value)
		for _, item in value do
			Profile.freeze(item)
		end
	end
end

function Profile.new(
	key: string,
	loadCount: number,
	lastSavedAt: number,
	record: any,
	spawn: (fn: (...any) -> (), ...any) -> (),
	backing: Backing
): Profile
	return {
		Data = record.Data,
		LastSavedData = Record.copy(record.Data),
		UserIds = table.clone(record.UserIds or {}),
		RobloxMetaData = table.clone(record.RobloxMetaData or {}),
		key = key,
		loadCount = loadCount,
		createdAt = record.MetaData and record.MetaData.ProfileCreateTime or 0,
		lastSavedAt = lastSavedAt,
		onSaving = Signal.new(spawn),
		onSaved = Signal.new(spawn),
		onEnded = Signal.new(spawn),
		isActive = function(_: Profile): boolean
			return backing.isActive()
		end,
		save = function(_: Profile): boolean
			return backing.save()
		end,
		release = function(_: Profile)
			backing.release()
		end,
		onMessage = function(_: Profile, handler: (message: any, processed: () -> ()) -> ())
			assert(type(handler) == "function", "KeepBlox: onMessage needs a function")
			backing.handle(handler)
		end,
		addUserId = function(self: Profile, userId: number)
			assert(type(userId) == "number" and userId == math.floor(userId), "KeepBlox: a user id is an integer")
			if not table.find(self.UserIds, userId) then
				table.insert(self.UserIds, userId)
			end
		end,
		removeUserId = function(self: Profile, userId: number)
			const index = table.find(self.UserIds, userId)
			if index then
				table.remove(self.UserIds, index)
			end
		end,
	}
end

return Profile
