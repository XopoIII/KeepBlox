--!strict
--- A KeepBlox profile dressed as a ProfileStore profile: the same fields, methods and signals, so game
--- code written for ProfileStore runs unchanged.
---
--- Where behaviour differs, KeepBlox's guarantee wins, and the difference is listed in
--- `Compat/ProfileStore.luau`.
const Profile = require("../Profile")
const Record = require("../Record")
const Services = require("../Services")

export type Connection = { Disconnect: (self: Connection) -> () }
export type PSSignal = {
	Connect: (self: PSSignal, listener: (...any) -> ()) -> Connection,
	Fire: (self: PSSignal, ...any) -> (),
}

const CompatProfile = {}

--> A ProfileStore-style signal: `:Connect(fn)` returns `{Disconnect}`.
function CompatProfile.signal(spawn: (fn: (...any) -> (), ...any) -> ()): PSSignal
	const listeners: { { fn: (...any) -> (), live: boolean } } = {}
	return {
		Connect = function(_: PSSignal, listener: (...any) -> ()): Connection
			const entry = { fn = listener, live = true }
			table.insert(listeners, entry)
			return {
				Disconnect = function(_: Connection)
					entry.live = false
				end,
			}
		end,
		Fire = function(_: PSSignal, ...: any)
			for _, entry in table.clone(listeners) do
				if entry.live then
					spawn(entry.fn, ...)
				end
			end
		end,
	}
end

-- ProfileStore's reasons for a last save.
const LAST_SAVE_REASON: { [string]: string } = {
	released = "Manual",
	handedOver = "External",
	shutdown = "Shutdown",
	lost = "External",
}

--> Fills keys missing from `target` with copies from `template`, recursively (ProfileStore's
--> Reconcile). Existing values are never replaced.
CompatProfile.reconcile = Record.reconcile

--> The ProfileStore face of an open KeepBlox profile.
function CompatProfile.active(profile: Profile.Profile, template: { [any]: any }, services: Services.Services): any
	const spawn = services.clock.spawn
	local ended = false
	const self: any = {
		Data = profile.Data,
		LastSavedData = profile.LastSavedData,
		FirstSessionTime = profile.createdAt,
		SessionLoadCount = profile.loadCount,
		Session = { PlaceId = services.placeId, JobId = services.jobId },
		RobloxMetaData = profile.RobloxMetaData,
		UserIds = profile.UserIds,
		KeyInfo = nil,
		OnSave = CompatProfile.signal(spawn),
		OnLastSave = CompatProfile.signal(spawn),
		OnSessionEnd = CompatProfile.signal(spawn),
		OnAfterSave = CompatProfile.signal(spawn),
	}

	const function endOnce()
		if not ended then
			ended = true
			self.OnSessionEnd:Fire()
		end
	end

	profile.onSaving:connect(function(final: boolean, reason: Profile.EndReason?)
		self.OnSave:Fire()
		if final then
			self.OnLastSave:Fire(LAST_SAVE_REASON[reason or "released"])
			endOnce()
		end
	end)
	profile.onSaved:connect(function(saved: any)
		self.LastSavedData = saved
		self.OnAfterSave:Fire(saved)
	end)
	profile.onEnded:connect(function()
		endOnce()
	end)

	function self.IsActive(_: any): boolean
		return profile:isActive()
	end
	function self.Reconcile(this: any)
		CompatProfile.reconcile(this.Data, template)
	end
	function self.EndSession(_: any)
		-- ProfileStore returns at once and saves in the background; so does this.
		spawn(function()
			profile:release()
		end)
	end
	function self.Save(_: any)
		spawn(function()
			profile:save()
		end)
	end
	function self.AddUserId(_: any, userId: number)
		profile:addUserId(userId)
	end
	function self.RemoveUserId(_: any, userId: number)
		profile:removeUserId(userId)
	end
	function self.SetAsync(_: any)
		error("KeepBlox: :SetAsync() is only for profiles read with :GetAsync()", 2)
	end
	function self.MessageHandler(_: any, handler: (message: any, processed: () -> ()) -> ())
		profile:onMessage(handler)
	end
	return self
end

--> The ProfileStore face of a profile read without a session (`GetAsync`). `overwrite` stores its
--> data and clears any lock, as ProfileStore's view-mode `SetAsync` does.
function CompatProfile.view(
	record: any,
	template: { [any]: any },
	services: Services.Services,
	overwrite: (data: any) -> ()
): any
	const spawn = services.clock.spawn
	const self: any = {
		Data = record.Data,
		LastSavedData = Record.copy(record.Data),
		FirstSessionTime = record.MetaData and record.MetaData.ProfileCreateTime or 0,
		SessionLoadCount = record.MetaData and record.MetaData.SessionLoadCount or 0,
		Session = nil,
		RobloxMetaData = record.RobloxMetaData or {},
		UserIds = record.UserIds or {},
		KeyInfo = nil,
		OnSave = CompatProfile.signal(spawn),
		OnLastSave = CompatProfile.signal(spawn),
		OnSessionEnd = CompatProfile.signal(spawn),
		OnAfterSave = CompatProfile.signal(spawn),
	}
	function self.IsActive(_: any): boolean
		return false
	end
	function self.Reconcile(this: any)
		CompatProfile.reconcile(this.Data, template)
	end
	function self.EndSession(_: any) end
	function self.Save(_: any)
		error("KeepBlox: can't save a profile in view mode; use :SetAsync()", 2)
	end
	function self.AddUserId(this: any, userId: number)
		if not table.find(this.UserIds, userId) then
			table.insert(this.UserIds, userId)
		end
	end
	function self.RemoveUserId(this: any, userId: number)
		const index = table.find(this.UserIds, userId)
		if index then
			table.remove(this.UserIds, index)
		end
	end
	function self.SetAsync(this: any)
		overwrite(this.Data)
	end
	function self.MessageHandler(_: any)
		error("KeepBlox: messages are handled by an active session, not in view mode", 2)
	end
	return self
end

return CompatProfile
