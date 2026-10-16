--!strict
--- Mutants of the kind each report of the library hands `onError` (src/Report.luau): every site's kind
--- swapped for a neighbour's, which still type-checks. Kept apart from tests/Mutants.luau, which lists
--- them with the rest. Leaving a kind out, or naming one not on the list, is the type gate's to refuse.

type Mutant = { file: string, from: string, to: string, breaks: string }

-- `text` ends right before the kind's literal, and with it occurs once in `file`.
const function swap(file: string, text: string, kind: string, other: string, breaks: string): Mutant
	return { file = file, from = `{text}"{kind}"`, to = `{text}"{other}"`, breaks = breaks }
end

return {
	swap("src/Session.luau", "context.report(session.key, note, ", "repair", "refused", "a repair is a repair's"),
	swap(
		"src/Session.luau",
		"\n\t\t\tcontext.report(session.key, `not saved: {problem}`, ",
		"refused",
		"save",
		"data the checks refuse is refused"
	),
	swap(
		"src/Session.luau",
		"\t\t\t\tcontext.report(session.key, `not saved: {problem}`, ",
		"refused",
		"save",
		"data too large to store compressed is refused"
	),
	swap("src/Session.luau", "`save failed: {err}`, ", "save", "load", "a failed write is a save's"),
	swap(
		"src/Enter.luau",
		"a write failed after its caller was cancelled: {problem}`, ",
		"save",
		"release",
		"a write that throws with its caller cancelled is a save's"
	),
	swap(
		"src/Enter.luau",
		"a release failed after its caller was cancelled: {problem}`, ",
		"release",
		"save",
		"a release that throws with its caller cancelled is a release's"
	),
	swap("src/Enter.luau", "state.onError:fire(key, message, ", "message", "save", "a message handler that throws"),
	swap("src/Open.luau", "entered.message, ", "migration", "load", "data a load cannot use is a migration's"),
	swap(
		"src/Open.luau",
		"tried again: {problem}`,\n\t\t\t\t",
		"release",
		"load",
		"the release of a load nobody holds is a release's"
	),
	swap(
		"src/Open.luau",
		"a load failed after its caller was cancelled: {problem}`, ",
		"load",
		"release",
		"a load that throws with its caller cancelled is a load's"
	),
	swap("src/Claim.luau", "`load attempt failed: {err}`, ", "load", "save", "a failed try of a load is a load's"),
	swap("src/Claim.luau", 'and left untouched",\n\t\t', "quarantine", "load", "a quarantined value"),
	swap("src/LetGo.luau", "was not given back: {err}`, ", "release", "load", "a key a load did not give back"),
	swap(
		"src/LetGo.luau",
		"last beat could not be stored: {problem}`, ",
		"snapshot",
		"release",
		"a dead owner's beat a give-back could not store is a snapshot's"
	),
	swap("src/LetGo.luau", "could not be let go: {err}`, ", "release", "load", "a key not let go of"),
	swap(
		"src/LetGo.luau",
		"was not freed for the server asking for it: {err}`, ",
		"release",
		"save",
		"a stray key not freed"
	),
	swap("src/LetGo.luau", 'was freed for the server asking for it", ', "release", "save", "a stray key freed"),
	swap(
		"src/Recover.luau",
		'made against other data; the stored data is used",\n\t\t\t',
		"snapshot",
		"load",
		"a snapshot made against other data"
	),
	swap(
		"src/Recover.luau",
		'could not be stored; the stored data is used", ',
		"snapshot",
		"load",
		"a snapshot that could not be stored"
	),
	swap("src/Boards.luau", "not written: {problem}`, ", "leaderboard", "save", "a board not written"),
	swap("src/Boards.luau", "failed: {raw}`, ", "leaderboard", "save", "a board function that throws"),
	swap("src/Receipts.luau", "`no grant for product {receipt.ProductId}`, ", "receipt", "message", "no grant"),
	swap("src/Receipts.luau", "failed: {problem}`, ", "receipt", "message", "a grant that throws"),
	swap("src/Send.luau", "the queue is {outcome.kind}`, ", "message", "save", "a message refused"),
	swap("src/Send.luau", 'the data store kept failing", ', "message", "save", "a message not sent"),
	swap("src/Import.luau", "`import read failed: {value}`, ", "import", "load", "a failed read of the old store"),
	swap("src/Studio.luau", "chosen.notice, ", "studio", "load", "Studio in a place never published"),
	swap("src/Studio.luau", "Studio.notice(tostring(problem)), ", "studio", "load", "Studio without API access"),
	swap(
		"src/MockServices.luau",
		"starts from the template`,\n\t\t\t\t\t",
		"studio",
		"load",
		"a live profile copy could not read"
	),
} :: { Mutant }
