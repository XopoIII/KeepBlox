--!strict
--- Editing a key from a support tool or an admin command, whether its player is online or not.
---
---     const result = store:edit(`u_{userId}`, function(data)
---         data.coins += 100
---     end)
---     if not result.ok and result.reason == "inUse" then
---         store:message(`u_{userId}`, { grant = 100 })  -- online elsewhere: let that server apply it
---     end
---
--- - A profile open on this server is edited in place and saved.
--- - A key nobody holds is claimed quietly (see `LoadOptions.quiet`: no live owner is asked to hand
---   over, so no player is kicked), edited, and released. Migrations and defaults run as on any load.
--- - A key a live server holds is left alone: "inUse". Send it a message instead.
---
--- The edit either lands whole or not at all. When `edit` throws, or its result cannot be stored (the
--- schema refuses it, or it is not storable), the data goes back to what it was and nothing is written.
const Open = require("./Open")
const Record = require("./Record")
const Schema = require("./Schema")
const Session = require("./Session")
const Validate = require("./Validate")

export type Failure = Open.Failure | "error" | "refused" | "failed"

--> `data` is a copy of what was stored. `message` explains "error", "refused" and "failed".
export type Result = { ok: true, data: any } | { ok: false, reason: Failure, message: string? }

export type Options = {
	--> Polled while the claim waits; true gives up.
	cancel: (() -> boolean)?,
}

const Edit = {}

-- Puts `data` back to `before`, in place, so references the game holds stay valid.
const function restore(data: { [any]: any }, before: { [any]: any })
	for key in data do
		data[key] = nil
	end
	for key, value in before do
		data[key] = value
	end
end

-- Runs `edit` on `data`; on any problem restores it and says why.
const function apply(state: Open.State, data: any, edit: (data: any) -> ()): Result?
	const before = Record.copy(data)
	const ok, problem = pcall(edit, data)
	if not ok then
		restore(data, before)
		return { ok = false, reason = "error", message = tostring(problem) }
	end
	local _, refusal = Validate.check(data, "Data")
	if refusal == nil and state.plan.schema then
		refusal = Schema.check(state.plan.schema, data)
	end
	if refusal then
		restore(data, before)
		return { ok = false, reason = "refused", message = refusal }
	end
	return nil
end

function Edit.run(state: Open.State, key: string, edit: (data: any) -> (), options: Options?): Result
	assert(type(edit) == "function", "KeepBlox: edit needs a function")
	const live = state.sessions[key]
	if live and live.active and not live.releasing then
		const profile = live.profile
		const problem = apply(state, profile.Data, edit)
		if problem then
			return problem
		end
		if not Session.save(live.context, live) then
			return { ok = false, reason = "failed", message = "the save was not stored" }
		end
		return { ok = true, data = Record.copy(profile.Data) }
	end
	const loaded = Open.load(state, key, { quiet = true, cancel = options and options.cancel })
	if not loaded.ok then
		return { ok = false, reason = loaded.reason }
	end
	const profile = loaded.profile
	const problem = apply(state, profile.Data, edit)
	const data = Record.copy(profile.Data)
	profile:release()
	if problem then
		return problem
	end
	-- The release is the save: it must hold the edit (it does not when the key was lost meanwhile).
	const wanted = Validate.check(data, "Data")
	const saved = Validate.check(profile.LastSavedData, "Data")
	if wanted == nil or saved == nil or wanted.text ~= saved.text then
		return { ok = false, reason = "failed", message = "the release did not store the edit" }
	end
	return { ok = true, data = data }
end

return Edit
