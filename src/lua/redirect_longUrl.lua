local ngx = require("ngx")
local redis = require("resty.redis")
local mysql = require("resty.mysql")

local shortUrl = ngx.var.scheme .. "://" .. ngx.var.host .. ngx.var.request_uri

local g_red   -- redis handler
local g_db -- mysql hanlder

local g_redis_expire_time = 60 -- redis expire time(s)
local g_redis_timeout     = 10000 -- redis timeout(ms)
local g_redis_pool_size   = 100 -- redis connection pool size

local g_mysql_timeout     = 10000 -- mysql timeout(ms)
local g_mysql_pool_size   = 100 -- mysql connection pool size

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
    if not connect_redis() then
        return false
    end

    if not connect_mysql() then
        return false
    end

    -- 解析配置变量
    if ngx.var.redis_expire_time then
        g_redis_expire_time = ngx.var.redis_expire_time
    end

    if ngx.var.redis_timeout then
        g_redis_timeout = ngx.var.redis_timeout
    end

    if ngx.var.mysql_timeout then
        g_mysql_timeout = ngx.var.mysql_timeout
    end

    if ngx.var.redis_pool_size then
        g_redis_pool_size = ngx.var.redis_pool_size
    end

    if ngx.var.mysql_pool_size then
        g_mysql_pool_size = ngx.var.mysql_pool_size
    end

    -- 设置超时时间
    g_red:set_timeout(g_redis_timeout)
    g_db:set_timeout(g_mysql_timeout)

    return true
end


local function query_longUrl_from_db(shortUrl)
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

    return res[1].long_url
end

-- 更新 redis 缓存
local function set_shortUrl_cache(key, value)
    local ok = g_red:set(key, value)
    if not ok then
        return false
    end
    local success, err = g_red:expire(key, g_redis_expire_time)
    if not success then
        ngx.log(ngx.ERR, "Failed to refresh cache TTL for " .. key .. ": ", err)
        return false
    end
    return true
end

-- step1: 执行服务初始化
if not service_init() then
    ngx.redirect("/", ngx.HTTP_MOVED_TEMPORARILY)
    return
end


-- step2: 查 redis 缓存中是否存在
local longUrl = g_red:get("short:" .. shortUrl)
if type(longUrl) == "string" then
    ngx.redirect("/", ngx.HTTP_MOVED_TEMPORARILY)
    return
end

-- step3: 查 mysql 数据库中是否存在
longUrl = query_longUrl_from_db(shortUrl)
if not longUrl then
    ngx.redirect("/", ngx.HTTP_MOVED_TEMPORARILY)
    return
end

-- step4: 更新 redis 缓存
set_shortUrl_cache("short:" .. shortUrl, longUrl)

-- step5: 302 重定向到长网址
ngx.redirect(longUrl, ngx.HTTP_MOVED_TEMPORARILY)

-- step6: 使用连接池复用数据库连接
local ok, err
ok, err = g_red:set_keepalive(g_redis_timeout, g_redis_pool_size)
if not ok then
    ngx.log(ngx.ERR, "Failed to set redis keepalive: ", err)
end

ok, err = g_db:set_keepalive(g_mysql_timeout, g_mysql_pool_size)
if not ok then
    ngx.log(ngx.ERR, "Failed to set mysql keepalive: ", err)
    return
end