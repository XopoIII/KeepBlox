--!strict
--- MessagingService: a shared bus, and one server's handle onto it (the seam's `Services.Messaging`).
---
--- Sources: https://create.roblox.com/docs/reference/engine/classes/MessagingService and
--- https://create.roblox.com/docs/cloud-services/cross-server-messaging
--- - Topics are 1-80 characters; a message is at most 1 kB. Measured live (2026-09-30): a string
---   message may have 1024 bytes; any other value at most 940 bytes of JSON (the engine wraps it).
--- - Delivery is "typically within 1-2 seconds" and "best effort and not guaranteed". Order is not
---   documented, so it is not kept: each copy gets its own delay.
--- - The subscriber receives `{Data, Sent}`, `Sent` in Unix seconds with milliseconds (live). After Disconnect "the callback
---   should never be invoked".
---
--- The bus can drop, duplicate and delay messages, cut a server off (a partition: nothing reaches it or
--- leaves it), and make a server's SubscribeAsync hang, which is what Team Test does.
const Clock = require("./Clock")
const Encoding = require("./Encoding")
const Errors = require("./Errors")
const Faults = require("./Faults")
const Scheduler = require("./Scheduler")
const Services = require("@keepblox/Services")

type Subscription = {
	topic: string,
	server: string,
	callback: (Services.Message) -> (),
	connected: boolean,
}

export type Bus = {
	--> Probability that one delivery is lost, and that it arrives twice.
	drop: number,
	duplicate: number,
	--> Delivery delay range, in seconds.
	delay: { min: number, max: number },
	--> Servers cut off from the bus.
	partitioned: { [string]: boolean },
	--> Servers whose SubscribeAsync never returns.
	hangSubscribe: { [string]: boolean },
	--> Messages each server published (the benchmarks read it).
	read published: { [string]: number },
	--> A server's handle.
	handle: (self: Bus, server: string) -> Services.Messaging,
	--> Disconnects every subscription of `server` (it crashed).
	disconnectServer: (self: Bus, server: string) -> (),
	--> How many subscriptions `server` holds connected now (a leak shows here).
	connected: (self: Bus, server: string) -> number,
}

const TOPIC_LIMIT = 80
const STRING_LIMIT = 1024
const JSON_LIMIT = 940

const Messaging = {}

function Messaging.bus(scheduler: Scheduler.Scheduler, faults: Faults.Faults, epoch: number?): Bus
	const subscriptions: { Subscription } = {}
	const random = scheduler.random

	const function checkTopic(topic: string)
		if #topic > TOPIC_LIMIT then
			error(`MessagingService: Topic names cannot be more than {TOPIC_LIMIT} characters.`, 0)
		elseif #topic < 1 then
			error(Errors.unmodelled("an empty topic"), 0)
		end
	end

	const function deliver(bus: Bus, subscription: Subscription, message: Services.Message)
		scheduler:spawn(function()
			scheduler:wait(bus.delay.min + (bus.delay.max - bus.delay.min) * random:number())
			if subscription.connected and not bus.partitioned[subscription.server] then
				subscription.callback({ Data = Encoding.copy(message.Data), Sent = message.Sent })
			end
		end, subscription.server)
	end

	const bus: Bus = {
		drop = 0,
		duplicate = 0,
		delay = { min = 0.5, max = 2 },
		partitioned = {},
		hangSubscribe = {},
		published = {},

		handle = function(self: Bus, server: string): Services.Messaging
			const handle = {}

			function handle.PublishAsync(_: Services.Messaging, topic: string, data: any)
				checkTopic(topic)
				self.published[server] = (self.published[server] or 0) + 1
				if if type(data) == "string" then #data > STRING_LIMIT else Encoding.size(data) > JSON_LIMIT then
					error("MessagingService:PublishAsync(): Cannot publish, data exceeded 1kb", 0)
				end
				-- Stamped when the call is made, before its trip to the backend.
				const sent = Clock.trueMillis(scheduler, epoch) / 1000
				scheduler:wait(faults:sample())
				if self.partitioned[server] then
					return
				end
				const message = { Data = Encoding.copy(data), Sent = sent }
				for _, subscription in table.clone(subscriptions) do
					if subscription.topic == topic and subscription.connected and not random:chance(self.drop) then
						deliver(self, subscription, message)
						if random:chance(self.duplicate) then
							deliver(self, subscription, message)
						end
					end
				end
			end

			function handle.SubscribeAsync(
				_: Services.Messaging,
				topic: string,
				callback: (Services.Message) -> ()
			): Services.Connection
				checkTopic(topic)
				if self.hangSubscribe[server] then
					scheduler:wait(math.huge)
				end
				scheduler:wait(faults:sample())
				const rule = faults:match("SubscribeAsync", topic, server, false)
				if rule then
					if rule.hang then
						scheduler:wait(math.huge)
					end
					error(rule.error, 0)
				end
				const subscription: Subscription = {
					topic = topic,
					server = server,
					callback = callback,
					connected = true,
				}
				table.insert(subscriptions, subscription)
				return {
					Disconnect = function(_: Services.Connection)
						subscription.connected = false
					end,
				}
			end

			return handle :: Services.Messaging
		end,

		connected = function(_: Bus, server: string): number
			local count = 0
			for _, subscription in subscriptions do
				if subscription.server == server and subscription.connected then
					count += 1
				end
			end
			return count
		end,

		disconnectServer = function(_: Bus, server: string)
			for _, subscription in subscriptions do
				if subscription.server == server then
					subscription.connected = false
				end
			end
		end,
	}
	return bus
end

return Messaging
