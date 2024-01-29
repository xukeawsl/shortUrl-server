# 短链生成服务

[![License](https://img.shields.io/npm/l/mithril.svg)](https://github.com/xukeawsl/shortUrl-server/blob/master/LICENSE)

## 手动部署(以 CentOS7 为例)

1. 安装编译需要的库

```bash
yum -y update
yum -y install git
yum -y install wget
yum -y install gcc
yum -y install perl perl-devel
yum -y install pcre pcre-devel
yum -y install zlib zlib-devel

# 需要开启 ssl 时安装, 配置参数加上 --with-http_ssl_module
yum -y install openssl openssl-devel
```

2. 源码安装 openresty
```bash
wget https://openresty.org/download/openresty-1.25.3.1.tar.gz
tar -zxvf openresty-1.25.3.1.tar.gz
cd openresty-1.25.3.1
./configure && make && make install
```

3. 下载仓库文件
```bash
git clone https://github.com/xukeawsl/shortUrl-server.git
cd shortUrl-server
```

4. 编译 C 动态库并添加到搜索路径下
```bash
cd src
gcc -fPIC -shared libmurmur3.c -o libmurmur3.so
cp libmurmur3.so /usr/lib
ldconfig
```

5. 相关文件放置
```bash
# nginx 安装在 /usr/local/openresty/nginx 下, 先在其目录下一个lua目录
mkdir /usr/local/openresty/nginx/lua

# 将 src 下的 lua 文件放到 /usr/local/openresty/nginx/lua 目录下
cp *.lua /usr/local/openresty/nginx/lua/

# 将 static 目录拷贝到 nginx 目录下
cp -r ../static /usr/local/openresty/nginx/

# 将配置文件拷贝到 /usr/local/openresty/nginx/conf 下
cp ../conf/nginx.conf /usr/local/openresty/nginx/conf/
```

6. 安装 redis 数据库
```bash
yum -y install epel-release
yum -y install redis
```

7. 修改 redis 配置文件 `/etc/redis.conf`
```bash
vi /etc/redis.conf

# 放开以下两行的注释
unixsocket /tmp/redis.sock
unixsocketperm 700

# 启动 redis 服务
systemctl start redis
```

7. 安装 mysql 数据库并启动服务
```bash
yum -y install mariadb-server
systemctl start mariadb.service
```

8. 初始化配置
```bash
mysql_secure_installation

# Enter current password for root (enter for none): -- 按回车
# Set root password? [Y/n] -- 选 Y
# New password: -- 输入 root 后回车
# Re-enter new password: -- 输入 root 后回车
# Remove anonymous users? [Y/n] -- 选 Y
# Disallow root login remotely? [Y/n] -- 选 n
# Remove test database and access to it? [Y/n] -- 选 Y
# Reload privilege tables now? [Y/n] -- 选 Y
```

9. 建 mysql 数据库和表
```bash
mysql -u root -p

MariaDB [(none)]> create database mydb;
MariaDB [(none)]> use mydb;
MariaDB [mydb]> CREATE TABLE IF NOT EXISTS table_long_to_short (
    ->     short_url VARCHAR(255) PRIMARY KEY NOT NULL,
    ->     long_url VARCHAR(65535) NOT NULL,
    ->     join_count INT NOT NULL
    -> );
MariaDB [mydb]> exit;
```

10. 启动 nginx 服务
```bash
/usr/local/openresty/nginx/sbin/nginx
```