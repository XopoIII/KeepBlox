--!strict
--- The error texts the fakes raise, in the engine's "<code>: <message>" form.
---
--- Source: https://create.roblox.com/docs/cloud-services/data-stores/error-codes-and-limits
--- The library must classify errors by their code, never by the wording after it, so the wording here
--- only needs to be close.
---
--- `UNMODELLED` marks behaviour the docs leave open. The fakes refuse it loudly instead of guessing, so
--- the library cannot come to rely on a guess; a live check settles it, and then the fake models it.

const Errors = {}

function Errors.cantStore(what: string): string
	return `104: Cannot store {what} in data store.`
end

function Errors.valueTooLarge(limit: number): string
	return `105: Serialized value exceeds {limit} limit.`
end

function Errors.keyNameEmpty(): string
	return "101: Key name can't be empty."
end

function Errors.keyNameLimit(): string
	return "102: Key name exceeds the 50 character limit."
end

--> 301-306: the request waited for budget, but its queue (30 requests) was already full.
function Errors.queueFull(code: number, name: string): string
	return `{code}: {name} request dropped. Request was throttled but queue was full.`
end

function Errors.metadataTooLarge(limit: number): string
	return `511: Metadata attribute size exceeds {limit} limit.`
end

function Errors.attributeFormat(what: string): string
	return `513: Attribute {what} format is invalid.`
end

function Errors.rejected(): string
	return "502: API Services rejected request with error. HTTP 500 (Internal Server Error)"
end

function Errors.keyThrottled(): string
	return "KeyThrottled: the key's write throughput over the last 60 seconds is above its limit."
end

function Errors.unmodelled(what: string): string
	return `UNMODELLED: {what} is not documented by Roblox; the fake refuses it until a live check settles it.`
end

return Errors
