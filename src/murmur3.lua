-- murmur3_module.lua
local ffi = require("ffi")

local _M = {}

ffi.cdef[[
    uint32_t murmur3_32(const void* key, uint32_t len, uint32_t seed);
]]

local lib = ffi.load("murmur3")

function _M.murmur3_32(key, len, seed)
    return lib.murmur3_32(key, len, seed)
end

return _M