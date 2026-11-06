#!/bin/bash
# nginx-static-build.sh - 把自编译 nginx 用"同版本 + 同 configure 参数 + 静态 OpenSSL/PCRE"重新编译，
#                         只依赖 glibc/libcrypt/zlib，从 EL7 一路到 EL10 都能跑（过渡方案，最终换 nginx.org 官方包）
# 用法: bash nginx-static-build.sh /path/to/sbin/nginx [--install]
# 国内服务器常访问不了 GitHub：在本机下载 nginx-<ver>.tar.gz(.asc)、openssl-1.1.1w.tar.gz、pcre-8.45.tar.gz，上传到 /usr/local/src/nginx-static/ 即可
#   不带 --install 只编译到 /usr/local/src/nginx-static/，带上则备份原二进制并替换（不重启，需自己 nginx -t && reload/restart）
set -e
export LC_ALL=C
NG=${1:?用法: nginx-static-build.sh /path/to/nginx [--install]}
OPENSSL=openssl-1.1.1w; OPENSSL_SHA=cf3098950cb4d853ad95c0841f1f9c6d3dc102dccfcacd521d93925208b76ac8
PCRE=pcre-8.45;         PCRE_SHA=4e6ce03e0336e8b4a3d6c2b70b1c5e18590a5673a98186da90d4f33c23defc09
VER=$($NG -v 2>&1 | grep -oE "nginx/[0-9.]+" | cut -d/ -f2)
ARGS=$($NG -V 2>&1 | sed -n 's/^configure arguments: //p')
# 去掉原来的 openssl/pcre/cc-opt/ld-opt 相关参数，换成源码内置
# 注意只去掉 --with-openssl=PATH 这类带路径的，保留 --with-openssl-opt=...（曾误把它截成 "-opt=..."）
ARGS=$(echo "$ARGS" | sed -E 's/--with-(openssl|pcre|zlib)=[^ ]*//g; s/--with-pcre( |$)//g; s/--with-(cc|ld)-opt=("[^"]*"|'"'"'[^'"'"']*'"'"'|[^ ]*)//g; s/--with-pcre-jit//g')
echo "nginx $VER  configure: $ARGS"
command -v dnf >/dev/null && P=dnf || P=yum
$P -y install gcc make zlib-devel perl tar gzip curl gnupg2 >/dev/null 2>&1 || true
[ "$(rpm -E %rhel)" -ge 8 ] && $P -y install perl-core >/dev/null 2>&1 || true
W=/usr/local/src/nginx-static; mkdir -p $W; cd $W
get() { [ -s "$2" ] || curl -fsSL -m 300 -o "$2" "$1"; }
get https://nginx.org/download/nginx-$VER.tar.gz nginx-$VER.tar.gz
get https://nginx.org/download/nginx-$VER.tar.gz.asc nginx-$VER.tar.gz.asc
get https://github.com/openssl/openssl/releases/download/OpenSSL_1_1_1w/$OPENSSL.tar.gz $OPENSSL.tar.gz
get https://sourceforge.net/projects/pcre/files/pcre/8.45/$PCRE.tar.gz/download $PCRE.tar.gz
INSTALL=$2   # 下面不要再用 $1/$2
while read -r sum file; do
  echo "$sum  $file" | sha256sum -c - || { rm -f "$file"; echo "!! $file 不完整或被篡改，已删除。服务器访问不了 GitHub/SourceForge 时，在本机下载后上传到 $W/"; exit 1; }
done <<EOF
$OPENSSL_SHA $OPENSSL.tar.gz
$PCRE_SHA $PCRE.tar.gz
EOF
# nginx 源码用官方 PGP 签名校验（签名密钥来自 nginx.org/keys）
export GNUPGHOME=$W/gnupg; mkdir -p "$GNUPGHOME" && chmod 700 "$GNUPGHOME"
for k in nginx_signing pluknet sb thresh mdounin maxim arut; do curl -fsSL -m 30 https://nginx.org/keys/$k.key 2>/dev/null | gpg --import >/dev/null 2>&1 || true; done
# 老版本由已退任的维护者签名，其公钥已不在 nginx.org/keys（如 1.16.x 的 A1C052F8 / Maxim Dounin）：按签名里的 key ID 从公钥服务器取
if gpg --verify nginx-$VER.tar.gz.asc nginx-$VER.tar.gz 2>&1 | grep -q "No public key"; then
  kid=$(gpg --verify nginx-$VER.tar.gz.asc nginx-$VER.tar.gz 2>&1 | grep -oE "key ID [0-9A-F]+" | awk '{print $3}')
  for ks in hkps://keyserver.ubuntu.com hkp://keyserver.ubuntu.com:80 hkps://keys.openpgp.org; do timeout 40 gpg --keyserver "$ks" --recv-keys "$kid" >/dev/null 2>&1 && break; done
fi
gpg --verify nginx-$VER.tar.gz.asc nginx-$VER.tar.gz 2>&1 | grep -E "Good signature|BAD|Primary key fingerprint" || { echo "!! nginx 源码签名校验失败"; exit 1; }
gpg --verify nginx-$VER.tar.gz.asc nginx-$VER.tar.gz >/dev/null 2>&1 || { echo "!! nginx 源码签名校验失败"; exit 1; }
rm -rf nginx-$VER $OPENSSL $PCRE; for t in nginx-$VER $OPENSSL $PCRE; do tar xzf $t.tar.gz; done
cd nginx-$VER
eval ./configure $ARGS --with-openssl=../$OPENSSL --with-pcre=../$PCRE --with-cc-opt="'-O2 -Wno-error'" > ../configure.log 2>&1 || { tail -20 ../configure.log; exit 1; }
make -j"$(nproc)" > ../make.log 2>&1 || { tail -30 ../make.log; exit 1; }
./objs/nginx -V 2>&1 | head -3; echo "--- 动态依赖:"; ldd ./objs/nginx
ldd ./objs/nginx | grep -qE "libssl|libcrypto|libpcre" && { echo "!! 仍然动态链接了 ssl/pcre"; exit 1; }
if [ "$INSTALL" = "--install" ]; then
  cp -a "$NG" "$NG.bak-$(date +%Y%m%d%H%M)"; cp ./objs/nginx "$NG.new" && mv -f "$NG.new" "$NG"   # 运行中的二进制不能直接覆盖（Text file busy），用 rename 替换
  "$NG" -t && echo "已替换 $NG（原文件已备份）。执行: $NG -s stop; $NG  或 systemctl restart 对应服务"
else echo "编译完成: $W/nginx-$VER/objs/nginx （加 --install 替换）"; fi
