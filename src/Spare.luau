--!strict
--- A load's share of the server's data store budget: saves go first.
---
--- A save is what frees a key being handed over, and renewals keep sessions alive. A request fired at a
--- spent budget only fails (live: "StandardReadGameServerThrottled"), and a crowd of loads polling a
--- spent budget starved the owners' final saves, so hand-overs stalled and the polling grew (the live
--- load test, 2026-09-30). So a load's first try waits for one request, and its later tries leave
--- `RESERVE` to saves. The renewal loop spends down to the last request (see Upkeep).
const Types = require("./Types")

const Spare = {}

--> What a load's later tries leave to saves, in requests of each kind.
Spare.RESERVE = 10

const POLL = 0.5

--> Whether the server's budget holds `need` requests of both kinds a claim or a save spends.
function Spare.affords(context: Types.Context, need: number): boolean
	const dataStores = context.services.dataStores
	return dataStores:GetRequestBudgetForRequestType("StandardRead") >= need
		and dataStores:GetRequestBudgetForRequestType("StandardWrite") >= need
end

--> Waits until the budget holds `need` requests, or `deadline` passes, or `stop()` says so.
function Spare.wait(context: Types.Context, need: number, deadline: number, stop: () -> boolean)
	const clock = context.services.clock
	while not Spare.affords(context, need) and clock.now() < deadline and not stop() do
		clock.wait(math.min(POLL, deadline - clock.now()))
	end
end

return Spare
