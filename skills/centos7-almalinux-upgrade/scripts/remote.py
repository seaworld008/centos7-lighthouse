#!/usr/bin/env python3
"""remote.py - 通过 SSH 在目标服务器上执行命令 / 上传下载文件（本机运行，依赖 paramiko、openpyxl）。

凭据来源（按优先级）：
  1. --password-env VAR     从环境变量读取密码
  2. --inventory FILE       从资产表（.xlsx / .csv）按 host 或 name 查找
                            需要列：name, host, port, username, password（列名不区分大小写，可多一列 sudo_password 等）
                            也可设置环境变量 FLEET_INVENTORY 指向默认资产表
  3. 都没有时尝试 ~/.ssh 密钥 / ssh-agent（--key 可指定私钥）

用法：
  remote.py HOST run  "命令"            [--timeout 600]
  remote.py HOST script local.sh [args] [--timeout 600]   # 上传到 /root/os-upgrade-kit/ 后执行
  remote.py HOST put  LOCAL REMOTE                         # LOCAL 可为目录（递归）
  remote.py HOST get  REMOTE LOCAL
  remote.py HOST wait-ssh [--timeout 1800]                 # 等端口可连再返回（重启后用）
  remote.py --list                                         # 列出资产表中的主机（不显示密码）
  加 --sudo：以普通用户登录（AWS 的 centos/ec2-user）时用免密 sudo 以 root 执行/上传

注意：
  - 密码永远不打印、不放进命令行参数。
  - 已开启 SSH keepalive：OpenSSH < 8.2 + ClientAliveCountMax 0 会把空闲会话踢掉。
  - 超过几分钟的远程任务请用 systemd-run 后台执行再轮询，不要靠一个 SSH 会话挂着。
"""
import argparse
import csv
import os
import socket
import sys
import time

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

import paramiko

KIT_DIR = "/root/os-upgrade-kit"


def fix_remote_path(p):
    """Git Bash(MSYS) 会改写以 / 开头的参数：/root/x → C:/Program Files/Git/root/x，/tmp/x → %TEMP%/x。
    这里还原成远端路径；无法还原的 Windows 路径直接报错（可设 MSYS_NO_PATHCONV=1 或写成 //root/x）。"""
    import re
    q = p.replace("\\", "/")
    m = re.match(r"^[A-Za-z]:/.*?/Git/(.*)$", q)
    if m:
        return "/" + m.group(1)
    for env in ("TEMP", "TMP"):
        t = (os.environ.get(env) or "").replace("\\", "/").rstrip("/")
        if t and q.lower().startswith(t.lower() + "/"):
            return "/tmp/" + q[len(t) + 1:]
    if q.startswith("//"):
        return q[1:]
    if re.match(r"^[A-Za-z]:/", q):
        sys.exit("[remote.py] 远端路径 %r 看起来被 Git Bash 改写成了 Windows 路径；请设置 MSYS_NO_PATHCONV=1 后重试，或写成 //root/xxx" % p)
    return p


def load_inventory(path):
    rows = []
    if path.lower().endswith((".xlsx", ".xlsm")):
        import openpyxl
        wb = openpyxl.load_workbook(path, data_only=True, read_only=True)
        for ws in wb.worksheets:
            it = ws.iter_rows(values_only=True)
            try:
                header = [str(h or "").strip().lower() for h in next(it)]
            except StopIteration:
                continue
            for r in it:
                if not any(r):
                    continue
                rows.append({header[i]: ("" if v is None else str(v).strip()) for i, v in enumerate(r) if i < len(header)})
    else:
        with open(path, newline="", encoding="utf-8-sig") as f:
            for r in csv.DictReader(f):
                rows.append({(k or "").strip().lower(): (v or "").strip() for k, v in r.items()})
    return rows


def find_host(rows, key):
    for r in rows:
        if key in (r.get("host"), r.get("name"), r.get("ip")):
            return r
    return None


def connect(args):
    host, port, user, password = args.host, args.port, args.user, None
    if args.password_env:
        password = os.environ.get(args.password_env)
    inv = args.inventory or os.environ.get("FLEET_INVENTORY")
    if inv and os.path.exists(inv):
        r = find_host(load_inventory(inv), args.host)
        if r:
            host = r.get("host") or r.get("ip") or host
            port = port or int(float(r.get("port") or 22))
            user = user or r.get("username") or r.get("user")
            password = password or r.get("password") or None
    port = port or 22
    user = user or "root"
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    kw = dict(hostname=host, port=port, username=user, timeout=20, banner_timeout=30, auth_timeout=30)
    if password:
        kw.update(password=password, look_for_keys=False, allow_agent=False)
    elif args.key:
        kw.update(key_filename=args.key)
    c.connect(**kw)
    c.get_transport().set_keepalive(30)
    return c, host, port


def run(c, cmd, timeout):
    _, o, e = c.exec_command(cmd, timeout=timeout, get_pty=False)
    try:
        for line in iter(o.readline, ""):
            print(line, end="")
    except socket.timeout:
        print("\n[remote.py] 读取超时：命令可能仍在远端运行。长任务请用 systemd-run 后台执行再轮询。")
        return 124
    err = e.read().decode(errors="replace")
    if err.strip():
        print("[stderr]\n" + err)
    rc = o.channel.recv_exit_status()
    print("[exit]", rc)
    return rc


def put(c, local, remote):
    s = c.open_sftp()

    def mkdirs(p):
        parts = p.strip("/").split("/")
        cur = ""
        for part in parts:
            cur += "/" + part
            try:
                s.stat(cur)
            except IOError:
                s.mkdir(cur)

    if os.path.isdir(local):
        for root, dirs, files in os.walk(local):
            dirs[:] = [d for d in dirs if d not in ("__pycache__", ".git")]
            rel = os.path.relpath(root, local).replace("\\", "/")
            rdir = remote if rel == "." else remote.rstrip("/") + "/" + rel
            mkdirs(rdir)
            for f in files:
                s.put(os.path.join(root, f), rdir + "/" + f)
                print("uploaded", rdir + "/" + f)
    else:
        mkdirs(os.path.dirname(remote) or "/")
        s.put(local, remote)
        print("uploaded", remote)
    s.close()


def wait_ssh(host, port, timeout):
    t0 = time.time()
    # 先等它掉线（最多 120 秒），再等它回来
    while time.time() - t0 < 120:
        try:
            socket.create_connection((host, port), 3).close()
            time.sleep(5)
        except OSError:
            break
    while time.time() - t0 < timeout:
        try:
            socket.create_connection((host, port), 5).close()
            print("ssh-port-open after %ds" % (time.time() - t0))
            return 0
        except OSError:
            time.sleep(5)
    print("timeout waiting for ssh (%ds) - 去云控制台 VNC/串口看看" % timeout)
    return 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("host", nargs="?")
    ap.add_argument("action", nargs="?", choices=["run", "script", "put", "get", "wait-ssh"])
    ap.add_argument("rest", nargs="*")
    ap.add_argument("--inventory")
    ap.add_argument("--password-env")
    ap.add_argument("--key")
    ap.add_argument("--port", type=int)
    ap.add_argument("--user")
    ap.add_argument("--timeout", type=int, default=600)
    ap.add_argument("--sudo", action="store_true", help="非 root 登录时用 sudo -n 以 root 执行（需免密 sudo）")
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()

    if args.list:
        inv = args.inventory or os.environ.get("FLEET_INVENTORY")
        for r in load_inventory(inv):
            print("\t".join([r.get("name", ""), r.get("host", ""), r.get("port", ""), r.get("username", ""), r.get("os_type", ""), r.get("region", "")]))
        return 0
    if not args.host or not args.action:
        ap.print_help()
        return 2

    if args.action == "wait-ssh":
        _, host, port = None, args.host, args.port
        inv = args.inventory or os.environ.get("FLEET_INVENTORY")
        if inv:
            r = find_host(load_inventory(inv), args.host)
            if r:
                host = r.get("host") or host
                port = port or int(float(r.get("port") or 22))
        return wait_ssh(host, port or 22, args.timeout)

    c, _, _ = connect(args)

    def q(s):
        return "'" + s.replace("'", "'\\''") + "'"

    def wrap(cmd):  # 非 root 用户（AWS centos/ec2-user 等）：sudo -n 以 root 执行
        return "sudo -n bash -c %s" % q(cmd) if args.sudo else cmd

    def put_any(local, remote):
        if not args.sudo:
            return put(c, local, remote)
        tmp = "/tmp/.remote-put-%d" % os.getpid()
        put(c, local, tmp + ("" if os.path.isdir(local) else "/" + os.path.basename(remote)))
        src = tmp + ("/." if os.path.isdir(local) else "/" + os.path.basename(remote))
        dst = remote if os.path.isdir(local) else os.path.dirname(remote)
        run(c, wrap("mkdir -p %s && cp -r %s %s && rm -rf %s" % (q(dst), q(src), q(dst + ("/" if os.path.isdir(local) else "")), q(tmp))), 120)

    try:
        if args.action == "run":
            cmd = " ".join(args.rest) if args.rest else sys.stdin.read()
            return run(c, wrap(cmd), args.timeout)
        if args.action == "script":
            local, sargs = args.rest[0], args.rest[1:]
            remote = KIT_DIR + "/" + os.path.basename(local)
            put_any(local, remote)
            return run(c, wrap("bash %s %s" % (remote, " ".join(q(a) for a in sargs))), args.timeout)
        if args.action == "put":
            put_any(args.rest[0], fix_remote_path(args.rest[1]))
            return 0
        if args.action == "get":
            s = c.open_sftp()
            s.get(fix_remote_path(args.rest[0]), args.rest[1])
            print("downloaded", args.rest[1])
            return 0
    finally:
        c.close()


if __name__ == "__main__":
    sys.exit(main() or 0)
