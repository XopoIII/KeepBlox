--!strict
--- The seam's `Codec` over Lune's serde: JSON as `HttpService:JSONEncode`/`JSONDecode`, and Zstandard as
--- `EncodingService:CompressBuffer`/`DecompressBuffer` with `Enum.CompressionAlgorithm.Zstd`
--- (https://create.roblox.com/docs/reference/engine/classes/EncodingService). Neither call yields.
const Services = require("@keepblox/Services")
const serde = require("@lune/serde")

const Codec = {}

function Codec.new(): Services.Codec
	return {
		encode = function(value: any): string
			return serde.encode("json", value)
		end,
		decode = function(text: string): any
			return serde.decode("json", text)
		end,
		compress = function(text: string): buffer
			return buffer.fromstring(serde.compress("zstd", text, 3))
		end,
		decompress = function(packed: buffer): string
			return serde.decompress("zstd", buffer.tostring(packed))
		end,
	}
end

return Codec
