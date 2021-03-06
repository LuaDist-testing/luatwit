--- Lua library for accessing the Twitter REST and Streaming API v1.1
--
-- @module  luatwit
-- @author  darkstalker <https://github.com/darkstalker>
-- @license MIT/X11
local assert, error, ipairs, next, pairs, require, setmetatable, type =
      assert, error, ipairs, next, pairs, require, setmetatable, type
local oauth = require "oauth_light"
local json = require "dkjson"
local common = require "luatwit.common"

local _M = {}

--- Class prototype that implements the API calls.
-- Methods are created on demand from the definitions in the `self.resources` table (by default `luatwit.resources`).
-- @type api
local api = {}
_M.api = api

-- Builds the request url and arguments for the OAuth call.
local function build_request(base_url, path, args, rules, defaults)
    local request = {}
    if defaults then
        for k, v in pairs(defaults) do
            if rules[k] ~= nil then
                request[k] = v
            end
        end
    end
    for k, v in pairs(args) do
        if k:sub(1, 1) ~= "_" then
            request[k] = v
        end
    end
    path = path:gsub(":([%w_]+)", function(key)
        local val = request[key]
        assert(val ~= nil, "invalid token ':" .. key .. "' in resource URL")
        request[key] = nil
        return val
    end)
    return base_url:format(path), request
end

-- Guesses an object's type by checking known field names.
local function guess_type(self, data)
    for field, tname in pairs(self.type_hints) do
        if data[field] ~= nil then
            return tname
        end
    end
end

-- Applies type metatables to the supplied JSON data recursively.
local function apply_types(self, node, tname)
    if tname == "_guess" then
        tname = guess_type(self, node)
    end
    if tname == nil then return node end
    local type_decl = self.objects[tname]
    local st = type_decl._subtypes
    if st ~= nil then
        local type_st = type(st)
        if type_st == "string" then
            for _, item in ipairs(node) do
                apply_types(self, item, st)
            end
        elseif type_st == "table" then
            for k, tn in pairs(st) do
                local item = node[k]
                if item ~= nil then
                    apply_types(self, item, tn)
                end
            end
        else
            error "subtype declaration must be string or table"
        end
    end
    node._get_client = self._get_client
    return setmetatable(node, type_decl)
end

--- Generic call to the Twitter API.
-- This is the backend method that performs all the API calls.
--
-- @param decl      Resource declaration (from `luatwit.resources`).
-- @param args      Table with the method arguments.
-- @param defaults  Default method arguments (used internally).
-- @return          A table with the decoded JSON data from the response, or `nil` on error.
--                  If the option `_async` or `_callback` is set, instead it returns a `luatwit.http.future` object.
--                  If a streaming method is called, instead it returns a `luatwit.http.stream` object.
-- @return          HTTP headers. On error, instead it will be a string or a `luatwit.objects.error` describing the error.
-- @return          If an API error ocurred, the HTTP headers of the request.
function api:raw_call(decl, args, defaults)
    args = args or {}
    local name = decl.name or "raw_call"
    local rules = decl.rules
    if rules then assert(rules(args, name)) end

    local base_url = decl.base_url or self.resources._base_url
    local url, request = build_request(base_url, decl.path, args, rules and rules.optional, defaults)

    local function parse_response(body, res_code, headers)
        local data, err, code = self:_parse_response(body, res_code, headers, decl.res_type)
        if data == nil then
            return nil, err, code
        end
        if type(data) == "table" and data._type then
            data._source = name
            if next(request) then
                data._request = request
            end
            if not decl.stream and data._type == "error" then
                return nil, data, headers
            end
        end
        return data, headers
    end

    local req_url, req_body, req_headers = oauth.build_request(decl.method, url, request, self.oauth_config, decl.multipart)

    return self:http_request{
        method = decl.method, url = req_url, body = req_body, headers = req_headers,
        _async = args._async, _callback = args._callback, _stream = decl.stream, _filter = parse_response,
    }
end

-- Parses a JSON string and applies type metatables.
local function parse_json(self, str, tname, code)
    local json_data, _, err = json.decode(str, 1, _M.null, nil)
    if json_data == nil then
        return nil, err
    end
    if type(json_data) ~= "table" then
        return json_data
    end
    if code < 200 or code >= 300 then
        tname = "error"
    end
    if tname then
        apply_types(self, json_data, tname)
    end
    return json_data
end

-- Parses a form encoded OAuth token.
local function parse_oauth_token(self, body, tname)
    local token = oauth.form_decode_pairs(body)
    if token.oauth_token == nil or token.oauth_token_secret == nil then
        return nil, "received invalid token"
    end
    self.oauth_config.oauth_token = token.oauth_token
    self.oauth_config.oauth_token_secret = token.oauth_token_secret
    return apply_types(self, token, tname)
end

-- Parses the response body according to the content-type value.
function api:_parse_response(body, res_code, headers, tname)
    -- The method failed, error is on second arg
    if body == nil then
        return nil, res_code
    end
    local content_type = headers:get_content_type()
    -- HTTP request failed, the error message is returned as json
    if (res_code < 200 or res_code >= 300) and content_type ~= "application/json" then
        return nil, headers[1], res_code
    end
    if content_type == "application/json" then
        return parse_json(self, body, tname, res_code)
    elseif tname == "access_token" then -- twitter returns "text/html" as content-type for the tokens..
        return parse_oauth_token(self, body, tname)
    else
        return body
    end
end

--- Generates the OAuth authorization URL.
--
-- @return      Authorization URL.
function api:oauth_authorize_url()
    assert(self.oauth_config.oauth_token, "no oauth_token")
    return self.resources._authorize_url .. "?oauth_token=" .. oauth.url_encode(self.oauth_config.oauth_token)
end

--- Sets the callback handler function.
-- The callback handler is called after every async request that uses the `_callback` option. This function has to do the
-- necessary setup to watch the future/stream and send the result to the callback when it's ready.
-- This way we can work with external event loops in a transparent way.
--
-- @param fn    Callback handler function. This is called as `fn(fut, callback)`, where `fut` is the result from an async
--              API call and `callback` is the value passed in the request's `_callback` argument.
function api:set_callback_handler(fn)
    self.callback_handler = fn
end

local http_request_args = common.build_rules{
    url = { type = "string", required = true },
    method = "string",
    body = "any",   -- string or table
    headers = "table",
}

--- Performs an HTTP request.
-- This method allows using the library features (like callback_handler) with regular HTTP requests.
--
-- @param args  Table with request arguments (method, url, body, headers, _async, _callback, _stream).
-- @return      Request response.
-- @see luatwit.http.service:request, luatwit.http.service:async_request
function api:http_request(args)
    assert(http_request_args(args, "http_request"))
    assert(not args._callback or self.callback_handler, "need callback handler")
    assert(not args._stream or args._async or args._callback, "streaming requires async interface")

    if args._async or args._callback then
        local fut = self.http:async_request(args.method, args.url, args.body, args.headers, args._filter, args._stream)
        if args._callback then
            return fut, self.callback_handler(fut, args._callback)
        end
        return fut
    else
        return self.http:request(args.method, args.url, args.body, args.headers, args._filter)
    end
end

-- inherit from `api` and `resources`
local function api_index(self, key)
    return api[key] or self.resources[key]
end

local api_new_args = common.build_rules{
    consumer_key = { type = "string", required = true },
    consumer_secret = { type = "string", required = true },
    oauth_token = "string",
    oauth_token_secret = "string",
}

--- Creates a new `api` object with the supplied keys.
-- An object created with only the consumer keys must call `api:oauth_request_token` and `api:oauth_access_token` to get the access token,
-- otherwise it won't be able to make API calls.
--
-- @param keys      Table with the OAuth keys (consumer_key, consumer_secret, oauth_token, oauth_token_secret).
-- @param http_svc  HTTP service instance (default new instance of `luatwit.http.service`).
-- @param resources Table with the API interface definition (default `luatwit.resources`).
-- @param objects   Table with the API objects definition (default `luatwit.objects`).
-- @return          New instance of the `api` class.
-- @see luatwit.objects.access_token
function api.new(keys, http_svc, resources, objects)
    assert(api_new_args(keys, "api.new"))

    local self = {
        __index = api_index,
        resources = resources or require("luatwit.resources"),
        objects = objects or require("luatwit.objects"),
        type_hints = {},
        oauth_config = {
            consumer_key = keys.consumer_key,
            consumer_secret = keys.consumer_secret,
            oauth_token = keys.oauth_token,
            oauth_token_secret = keys.oauth_token_secret,
            sig_method = "HMAC-SHA1",
            use_auth_header = true,
        },
        http = http_svc or require("luatwit.http").service:new(),
    }
    self._get_client = function() return self end

    -- collect type hints
    for name, item in pairs(self.objects) do
        local hint = item._type_hint
        if hint then
            self.type_hints[hint] = name
        end
    end

    return setmetatable(self, self)
end

return _M
