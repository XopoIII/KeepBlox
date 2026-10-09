--!strict
--- Compressing large profiles, so data past the 4 MB a key may hold still saves (ProfileService#24,
--- ProfileStore#7, DocumentService#112).
---
---     KeepBlox.store("Profiles", { template = TEMPLATE, compress = { above = 1_000_000 } })
---
--- A profile whose data is over `above` bytes is stored as `{ __KeepBlox = "zstd1", z = <buffer> }`: its
--- JSON text compressed with Zstandard. Smaller profiles are stored as they are. The 4 MB limit applies to
--- what is stored, so a compressed profile may be many times larger in memory.
---
--- Off by default, and for a reason: ProfileStore cannot read a compressed profile. Turn it on only when
--- every server runs KeepBlox (it reads both forms, so it can be turned off again at any time). Data
--- holding buffers is never compressed (JSON cannot carry them); it is stored as it is.
const Services = require("./Services")
const Validate = require("./Validate")

export type Options = {
	--> Bytes of data from which a profile is compressed.
	above: number,
}

const MARK = "zstd1"

const Codec = {}

--> Whether `data` is a compressed profile.
function Codec.packed(data: any): boolean
	return type(data) == "table" and data.__KeepBlox == MARK and typeof(data.z) == "buffer"
end

--> The data `stored` holds: unpacked when compressed, as it is otherwise.
function Codec.unpack(codec: Services.Codec?, stored: any): any
	if not Codec.packed(stored) then
		return stored
	end
	assert(codec, "KeepBlox: this profile is compressed, and this server cannot decompress")
	return codec.decode(codec.decompress(stored.z))
end

--> What to store for `data` whose check is `encoded`: the data, or its compressed form. Nil and the
--> reason when it cannot be stored either way. The check knows the size and whether a buffer rules
--> compression out, so packing costs no second walk of the data.
function Codec.pack(codec: Services.Codec?, options: Options?, data: any, encoded: Validate.Encoded): (any, string?)
	local size = encoded.size
	if options == nil or size <= options.above or codec == nil or encoded.hasBuffer then
		if size > Validate.LIMIT then
			return nil, `Data: about {size} bytes, over the {Validate.LIMIT} byte limit`
		end
		return data, nil
	end
	const packed = { __KeepBlox = MARK, z = codec.compress(codec.encode(data)) }
	const checked = Validate.check(packed, "Data")
	if checked == nil then
		return nil, `Data: about {size} bytes, still over the {Validate.LIMIT} byte limit when compressed`
	end
	return packed, nil
end

return Codec
