--!strict
--- A deliberately unsafe library, for proving the ledger catches what it claims to: it reads with
--- GetAsync, takes the lock without asking anyone, and saves every 30 s with SetAsync whatever the
--- stored record says (much like a hand-rolled save module). Never a model to follow.
const Adapter = require("./Adapter")
const RobloxEnv = require("./RobloxEnv")

const STORE = "Naive"
const SAVE_EVERY = 30

const NaiveAdapter: Adapter.Adapter = {
	name = "Naive",
	store = `{STORE}/global`,
	boot = function(env: RobloxEnv.Env): Adapter.Library
		const game = env.globals.game
		const store = game:GetService("DataStoreService"):GetDataStore(STORE)
		const task = env.globals.task
		const session = { game.PlaceId, game.JobId, "naive" }

		return {
			open = function(key: string, hooks: Adapter.Hooks): Adapter.Session?
				const loaded = store:GetAsync(key, { UseCache = false })
				const count = if loaded then loaded.MetaData.SessionLoadCount + 1 else 1
				const data: Adapter.Data = if loaded then loaded.Data else { p = {} }
				local active = true
				const function save(final: boolean)
					const record = {
						Data = data,
						MetaData = {
							ActiveSession = if final then nil else session,
							SessionLoadCount = count,
						},
					}
					store:SetAsync(key, record)
					hooks.acked({ p = table.clone(data.p) })
				end
				save(false)
				task.spawn(function()
					while active do
						task.wait(SAVE_EVERY)
						if active then
							pcall(save, false)
						end
					end
				end)
				return {
					data = data,
					isActive = function(): boolean
						return active
					end,
					release = function()
						active = false
						pcall(save, true)
						hooks.ended()
					end,
				}
			end,
		}
	end,
}

return NaiveAdapter
