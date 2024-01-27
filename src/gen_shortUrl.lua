local ngx = require("ngx")
local json = require("cjson.safe")
local lib = require("murmur3")
local redis = require("resty.redis")
local mysql = require("resty.mysql")

local g_red   -- redis handler
local g_expire = 60 -- redis expire time(s)
local g_db -- mysql hanlder

-- 连接 redis 内存数据库
local function connect_redis()
    g_red = redis:new()
    if not g_red then
        return false
    end

    local ok = g_red:connect("unix:/tmp/redis.sock")
    if not ok then
        return false
    end

    return true
end


-- 连接 mysql 数据库
local function connect_mysql()
    g_db = mysql:new()
    if not g_db then
        return false
    end

    return g_db:connect{
        path = "/var/lib/mysql/mysql.sock",
        database = "mydb",
        user = "root",
        password = "root",
        charset = "utf8"
    }
end


-- 服务初始化设置
local function service_init()
    ngx.header.content_type = "application/json;charset=utf-8"
    ngx.status = ngx.HTTP_OK

    if not connect_redis() then
        return false
    end

    if not connect_mysql() then
        return false
    end

    -- 设置超时时间
    g_red:set_timeout(10000) -- 10 sec
    g_db:set_timeout(10000) -- 10 sec

    ngx.req.read_body() -- 读取请求体
    return true
end


-- 解析请求报文
local function parse_request(data)
    if not data then
        return nil
    end

    local decoded_data = json.decode(data)
    if not decoded_data then
        return nil
    end

    local value = decoded_data.longURL

    if not (value and type(value) == "string") then
        return nil
    end

    if string.sub(value, 1, 4) ~= "http" then
        return nil
    end

    return value
end


-- 设置返回报文
local function set_response(code, data, msg)
    local response = {
        code = code,
        data = data,
        msg = msg
    }
    ngx.say(json.encode(response))
end


-- 十进制整数转六十二进制字符串
local function decimal_to_base62(decimal)
    local chars = {'0','1','2','3','4','5','6','7','8','9',
                   'a','b','c','d','e','f','g','h','i','j',
                   'k','l','m','n','o','p','q','r','s','t',
                   'u','v','w','x','y','z','A','B','C','D',
                   'E','F','G','H','I','J','K','L','M','N',
                   'O','P','Q','R','S','T','U','V','W','X','Y','Z'}
    local result = {}

    repeat
        table.insert(result, 1, chars[(decimal % 62) + 1])
        decimal = math.floor(decimal / 62)
    until decimal == 0

    return table.concat(result, "")
end


-- 从 mysql 数据库中查询短网址是否有对应的长网址
local function query_longUrl_from_db(shortUrl, originUrl, join_count)
    local sql = [[
        SELECT long_url, join_count 
        FROM table_long_to_short
        WHERE short_url =
    ]] .. ngx.quote_sql_str(shortUrl)

    local res = g_db:query(sql)
    if not res then
        return nil
    end

    if #res == 0 then
        return nil
    end

    if originUrl ~= res[1].long_url then
        return nil
    end

    if join_count ~= res[1].join_count then
        return nil
    end

    return originUrl
end


-- 更新 redis 缓存
local function set_longUrl_cache(key, value)
    local ok = g_red:set(key, value)
    if not ok then
        return false
    end
    local success, err = g_red:expire(key, g_expire)
    if not success then
        ngx.log(ngx.ERR, "Failed to refresh cache TTL for " .. key .. ": ", err)
        return false
    end
    return true
end


-- 新增 mysql 值
local function set_longUrl_db(shortUrl, longUrl, join_count)
    local sql = "INSERT INTO table_long_to_short (short_url, long_url, join_count) VALUES (" 
    .. ngx.quote_sql_str(shortUrl) .. ", " .. ngx.quote_sql_str(longUrl) .. ", " .. join_count .. ")"

    local res, err, errno, sqlstate = g_db:query(sql)
    if not res then
        ngx.log(ngx.ERR, "Bad result: ", err, ": ", errno, ": ", sqlstate, ".")
    end
    return res
end


-- step1: 执行服务初始化
if not service_init() then
    set_response(ngx.HTTP_INTERNAL_SERVER_ERROR, "", "服务器发生内部错误")
    return
end


-- step2: 解析请求报文
local longUrl = parse_request(ngx.req.get_body_data())
if not longUrl then
    set_response(ngx.HTTP_BAD_REQUEST, "", "错误的请求格式")
    return
end

-- step3: 查缓存
local shortUrl = g_red:get("long:" .. longUrl)
if type(shortUrl) == "string" then
    set_response(ngx.HTTP_OK, shortUrl, "")
    return
end

-- step4: 若 mysql 中无记录, 则生成对应短网址
local originUrl = longUrl
local link_prefix = ngx.var.scheme .. "://" .. ngx.var.host .. "/"
local join_count = 0

while true do
    local hash_result = lib.murmur3_32(longUrl, #longUrl, 0)
    shortUrl = link_prefix .. decimal_to_base62(hash_result)

    local queryUrl = query_longUrl_from_db(shortUrl, originUrl, join_count)
    if queryUrl == originUrl then
        if not set_longUrl_cache("long:" .. originUrl, shortUrl) then
            set_response(ngx.HTTP_INTERNAL_SERVER_ERROR, "", "服务器发生内部错误")
        else
            set_response(ngx.HTTP_OK, shortUrl, "")
        end
        return
    end

    if not queryUrl then
        if not set_longUrl_db(shortUrl, originUrl, join_count) then
            set_response(ngx.HTTP_INTERNAL_SERVER_ERROR, "", "服务器发生内部错误")
        else
            if not set_longUrl_cache("long:" .. originUrl, shortUrl) then
                set_response(ngx.HTTP_INTERNAL_SERVER_ERROR, "", "服务器发生内部错误")
            else
                set_response(ngx.HTTP_OK, shortUrl, "")
            end
        end
        break
    end

    longUrl = longUrl .. "DUPLICATED"
    join_count = join_count + 1
end


-- step5: 使用连接池复用数据库连接
local ok, err
ok, err = g_red:set_keepalive(10000, 100)
if not ok then
    ngx.log(ngx.ERR, "Failed to set redis keepalive: ", err)
end

ok, err = g_db:set_keepalive(10000, 100)
if not ok then
    ngx.log(ngx.ERR, "Failed to set mysql keepalive: ", err)
    return
end