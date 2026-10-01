-- Deliberately uses surface excluded from Plugin API v1 or from this
-- plugin's local debug definitions. LuaLS must reject every statement below;
-- this file is never loaded by the host.

local alias_namespace = bitty.api
local legacy = bitty.on_event
local control = bitty.debug.control
local bad_target = bitty.debug.inspect("secrets")

print(alias_namespace, legacy, control, bad_target)
