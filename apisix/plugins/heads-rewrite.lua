--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
local core        = require("apisix.core")
local plugin_name = "heads-rewrite"
local ipairs      = ipairs

local schema = {
    type = "object",
    properties = {
        headers = {
            type = "array",
            minItems = 1,
            items = {
                type = "object",
                properties = {
                    head_vaule_on = {
                        type = "string",
                        default = "simple",
                        enum = {
                        "simple",
                        "vars",
                        "header",
                        "cookie",
                        "consumer",
                        "vars_combinations",
                        },
                    },
                    key = {
                        description = "the key of head_rewrite for dynamic load new head vaule ",
                        type = "string",
                        minLength = 1
                    },
                    head = {
                        description = "the head name",
                        type = "string",
                        pattern = "^[^:]+$"
                    }
                },
                required = {"head_vaule_on", "key", "head"},
            }
        }
    }
}


local _M = {
    version  = 0.1,
    priority = 1007,
    name     = plugin_name,
    schema   = schema,
}

local function get_headvaule_key_schema(head_vaule_on)
    if head_vaule_on == "simple" then
        return {
            type = "string",
            pattern = [[\S+]],
        }
    end

    if head_vaule_on == "vars" then
        return core.schema.upstream_hash_vars_schema
    end

    if head_vaule_on == "header" or head_vaule_on == "cookie" then
        return core.schema.upstream_hash_header_schema
    end

    if head_vaule_on == "consumer" then
        return nil, nil
    end

    if head_vaule_on == "vars_combinations" then
        return core.schema.upstream_hash_vars_combinations_schema
    end

    return nil, "invalid head_vaule_on type " .. head_vaule_on
end

local function fetch_headvaule_key(ctx, head_rewrite)
    local key = head_rewrite.key
    local head_vaule_on = head_rewrite.head_vaule_on or "vars"
    local head_vaule_key

    if head_vaule_on == "simple" then
        head_vaule_key = key
    elseif head_vaule_on == "consumer" then
        head_vaule_key = ctx.consumer_name
    elseif head_vaule_on == "vars" then
        head_vaule_key = ctx.var[key]
    elseif head_vaule_on == "header" then
        head_vaule_key = ctx.var["http_" .. key]
    elseif head_vaule_on == "cookie" then
        head_vaule_key = ctx.var["cookie_" .. key]
    elseif head_vaule_on == "vars_combinations" then
        local err, n_resolved
        head_vaule_key, err, n_resolved = core.utils.resolve_var(key, ctx.var)
        if err then
            core.log.error("could not resolve vars in ", key, " error: ", err)
        end

        if n_resolved == 0 then
            head_vaule_key = nil
        end
    end

    if not head_vaule_key then
        return nil, "head vaule is empty"
    end

    return head_vaule_key
end



function _M.check_schema(conf) 
    -- check headers
    if not conf.headers then
        return true
    end

    local ok, err = core.schema.check(schema, conf)
    if not ok then
        return false, err
    end


    for _, value in ipairs(conf.headers) do

        if not core.utils.validate_header_field(value.head) then
            return false, 'invalid field character in head'
        end

        if not value.head_vaule_on then
            goto continue
        end

        local key_schema, err = get_headvaule_key_schema(value.head_vaule_on)
        if err then
            return false, "head rewrite, err: " .. err
        end

        if key_schema then
            local ok, err = core.schema.check(key_schema, value.key)
            if not ok then
                return false, "invalid configuration: " .. err
            end
        end
        ::continue::
    end

    return true
end


do
    local upstream_vars = {
        host       = "upstream_host",
        upgrade    = "upstream_upgrade",
        connection = "upstream_connection",
    }

    function _M.rewrite(conf, ctx)
        core.log.warn("[heads-rewrite] conf-->", core.json.encode(conf, true))
        
        local headers = conf.headers

        for _, head_rewrite in ipairs(headers) do
            local head_name = head_rewrite.head
            local head_vaule, err = fetch_headvaule_key(ctx, head_rewrite)

            core.log.warn("[heads-rewrite] head_name-->", head_name, "; head_vaule-->", head_vaule)

            if err then
                error(err)
            end

            local new_head_name = upstream_vars[head_name]
            if new_head_name then
                ctx.var[new_head_name] = head_vaule
            else
                core.request.set_header(ctx, head_name, head_vaule)
            end
        end
    end

end  -- do


return _M
