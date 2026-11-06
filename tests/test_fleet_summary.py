"""Unit tests for skills/centos7-almalinux-upgrade/scripts/fleet_summary.py (stdlib unittest; run: python -m unittest discover -s tests)."""
import importlib.util
import io
import os
import tempfile
import unittest
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = importlib.util.spec_from_file_location(
    "fleet_summary", os.path.join(HERE, "..", "skills", "centos7-almalinux-upgrade", "scripts", "fleet_summary.py"))
fs = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fs)


def survey(os_line="CentOS Linux release 7.9.2009 (Core)", el=7, cloud="aliyun", v3="YES", containers=(), flags=()):
    ctr = "\n".join("/%s | img:1 | running | always | bridge | /data/x" % c for c in containers)
    fl = "\n".join("[%s] %s" % f for f in flags) or "(none)"
    return ("\n===== OS =====\n%s\nkernel=3.10 arch=x86_64 el=%d\nvirt=kvm dmi='x' cloud=%s\n\n===== CPU =====\nx86-64-v3: %s\n"
            "\n===== DOCKER/CONTAINERS =====\nserver=20.10\n%s\n\n===== KUBERNETES =====\n\n"
            "################ RISK FLAGS ################\n%s\n############################################\n") % (os_line, el, cloud, v3, ctr, fl)


class FleetSummaryTest(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()

    def add(self, host, text):
        os.makedirs(os.path.join(self.d, host))
        with open(os.path.join(self.d, host, "survey.txt"), "w", encoding="utf-8") as f:
            f.write(text)

    def test_parse(self):
        info = fs.parse_survey(survey(containers=("a", "b"), flags=(("HIGH", "x"), ("BLOCKER", "y"))))
        self.assertEqual(info["el"], 7)
        self.assertEqual(info["containers"], 2)
        self.assertTrue(info["v3"])
        self.assertEqual([lv for lv, _ in info["flags"]], ["HIGH", "BLOCKER"])

    def test_classification(self):
        self.add("simple", survey())
        self.add("docker", survey(containers=("web",)))
        self.add("custom", survey(flags=(("HIGH", "自编译程序 /opt/nginx 依赖 EL7 库"),)))
        self.add("k8s", survey(flags=(("BLOCKER", "本机是 Kubernetes 节点（kubelet 运行中）"),)))
        self.add("vpn", survey(containers=("vpn",), flags=(("BLOCKER", "本机运行 VPN/隧道（netbird）"),)))
        self.add("c8", survey(os_line="CentOS Linux release 8.3.2011", el=8))
        hosts = {h["host"]: h for h in fs.load(self.d)}
        self.assertEqual(hosts["simple"]["cls"], "A")
        self.assertEqual(hosts["docker"]["cls"], "B")
        self.assertEqual(hosts["custom"]["cls"], "C")
        self.assertEqual(hosts["k8s"]["cls"], "D")
        self.assertTrue(hosts["vpn"]["vpn"])
        self.assertTrue(hosts["c8"]["el8"])

    def test_plan_canary_groups_vpn_last_and_d_excluded(self):
        for i in range(4):
            self.add("a%d" % i, survey())
        self.add("b0", survey(containers=("x",)))
        self.add("vpn", survey(flags=(("BLOCKER", "本机运行 VPN/隧道（wireguard）"),)))
        self.add("k8s", survey(flags=(("BLOCKER", "本机是 Kubernetes 节点"),)))
        hosts = fs.load(self.d)
        waves = fs.plan(hosts, {"a1": "erp", "a2": "erp"}, batch=5)
        names = [[h["host"] for h in w] for w in waves]
        self.assertEqual(names[0], ["a0", "b0"])                       # canary per class
        flat = [n for w in names for n in w]
        self.assertNotIn("k8s", flat)                                   # D excluded
        self.assertEqual(flat[-1], "vpn")                               # VPN last
        for w in names:                                                 # same group never in one wave
            self.assertFalse({"a1", "a2"} <= set(w))

    def test_cli_markdown(self):
        self.add("web-01", survey(containers=("app",)))
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = fs.main([self.d])
        self.assertEqual(rc, 0)
        self.assertIn("| web-01 |", buf.getvalue())
        self.assertIn("建议批次", buf.getvalue())


if __name__ == "__main__":
    unittest.main()
