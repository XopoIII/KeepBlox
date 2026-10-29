--!strict
--- Mutants of a release whose earlier try landed unanswered (src/Lock.luau): its retry finds the key let
--- go by its own session and ends as released, while a key another server took is still lost. Kept apart
--- from tests/Mutants.luau, which lists them with the rest.

return {
	{
		file = "src/Lock.luau",
		from = "\tif\n\t\tpayload.release\n\t\tand active == nil\n",
		to = "\tif\n\t\tfalse\n\t\tand active == nil\n",
		breaks = "a release that landed unanswered ends as released, not lost",
	},
	{
		file = "src/Lock.luau",
		from = "\t\tand Record.ours(meta).owner == identity.guid\n\tthen",
		to = "\t\tand true\n\tthen",
		breaks = "a key let go by another session is still lost to this one",
	},
	{
		file = "src/Lock.luau",
		from = "\t\tpayload.release\n\t\tand active == nil\n\t\tand meta.SessionLoadCount == loadCount\n",
		to = "\t\tpayload.release\n\t\tand active == nil\n\t\tand true\n",
		breaks = "an older session's release of this server is still lost",
	},
}
