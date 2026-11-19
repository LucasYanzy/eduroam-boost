import json
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
import eduroam_boost as eb  # noqa: E402

FX = os.path.join(os.path.dirname(__file__), "fixtures")


def fixture(name):
    with open(os.path.join(FX, name)) as fh:
        return fh.read()


def sample(band="5GHz", gw=5.0, loss=0.0, fast=(), ts=None, bad=None):
    s = {"ts": (ts or datetime(2026, 1, 1, 10)).isoformat(timespec="seconds"),
         "link": None if band is None else {"band": band, "channel": "x", "rssi": -60, "noise": -94, "rate": 100,
                                             "enterprise": True, "fast_nearby": list(fast)},
         "gw_ms": gw, "gw_loss": loss}
    if bad is not None:
        s["bad"] = bad
    return s


class ParseTests(unittest.TestCase):
    def test_parse_link_24ghz_with_faster_enterprise_nearby(self):
        link = eb.parse_link(json.loads(fixture("airport-24ghz.json")))
        self.assertEqual(link["band"], "2.4GHz")
        self.assertEqual(link["rssi"], -73)
        self.assertEqual(link["noise"], -94)
        self.assertEqual(link["rate"], 24)
        self.assertTrue(link["enterprise"])
        # personal 5 GHz network and the 2.4 GHz one are excluded
        self.assertEqual(link["fast_nearby"], ["157 (5GHz, 40MHz)", "37 (6GHz, 160MHz)"])

    def test_parse_link_5ghz(self):
        link = eb.parse_link(json.loads(fixture("airport-5ghz.json")))
        self.assertEqual(link["band"], "5GHz")
        self.assertEqual(link["fast_nearby"], [])

    def test_parse_link_garbage(self):
        self.assertIsNone(eb.parse_link({}))
        self.assertIsNone(eb.parse_link({"SPAirPortDataType": [{"spairport_airport_interfaces": [{"_name": "en0"}]}]}))

    def test_band_of(self):
        self.assertEqual(eb.band_of("37 (6GHz, 160MHz)"), "6GHz")
        self.assertEqual(eb.band_of("36 (5GHz, 80MHz)"), "5GHz")
        self.assertEqual(eb.band_of("6 (2GHz, 20MHz)"), "2.4GHz")
        self.assertEqual(eb.band_of(None), "?")

    def test_parse_ping(self):
        self.assertEqual(eb.parse_ping(fixture("ping-ok.txt")), (71.5, 10.0))
        self.assertEqual(eb.parse_ping(fixture("ping-dead.txt")), (None, 100.0))
        self.assertEqual(eb.parse_ping(""), (None, 100.0))


class JudgementTests(unittest.TestCase):
    def test_24ghz_with_faster_nearby_is_bad(self):
        self.assertTrue(eb.is_bad(sample("2.4GHz", fast=["157 (5GHz, 40MHz)"])))

    def test_24ghz_alone_and_fast_is_fine(self):
        self.assertFalse(eb.is_bad(sample("2.4GHz")))

    def test_latency_and_loss(self):
        self.assertEqual(len(eb.reasons(sample(gw=500, loss=20))), 2)
        self.assertTrue(eb.is_bad(sample(band=None)))

    def test_score_prefers_fast_band(self):
        self.assertLess(eb.score(sample("5GHz", 20)), eb.score(sample("2.4GHz", 20)))
        self.assertEqual(eb.score(sample(band=None)), 1e9)


class SummaryTests(unittest.TestCase):
    def test_boost_that_degraded_later(self):
        t0 = datetime(2026, 1, 1, 10)
        samples = [sample(ts=t0 + timedelta(minutes=1), bad=False),
                   sample(ts=t0 + timedelta(minutes=20), bad=False),
                   sample("2.4GHz", 400, ts=t0 + timedelta(minutes=45), bad=True)]
        boosts = [{"ts": t0.isoformat(), "trigger": "manual", "success": True, "tries": 1,
                   "before": sample("2.4GHz", 500), "after": sample("5GHz", 5)}]
        r = eb.summarize(samples, boosts)
        self.assertEqual(r["bands"], {"5GHz": 2, "2.4GHz": 1})
        self.assertAlmostEqual(r["bad_share"], 1 / 3)
        self.assertEqual(r["boosts"][0]["lasted_min"], 45.0)
        self.assertFalse(r["boosts"][0]["still_good"])

    def test_boost_still_holding(self):
        t0 = datetime(2026, 1, 1, 10)
        samples = [sample(ts=t0 + timedelta(minutes=m), bad=False) for m in (1, 30, 90)]
        boosts = [{"ts": t0.isoformat(), "trigger": "auto", "success": True, "tries": 2,
                   "before": sample("2.4GHz", 500), "after": sample("5GHz", 5)}]
        b = eb.summarize(samples, boosts)["boosts"][0]
        self.assertEqual((b["lasted_min"], b["still_good"]), (90.0, True))

    def test_empty(self):
        r = eb.summarize([], [])
        self.assertEqual((r["samples"], r["bad_share"], r["boosts"]), (0, None, []))


class BoostTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.patches = [mock.patch.object(eb, "DATA_DIR", self.tmp),
                        mock.patch.object(eb, "wifi_device", return_value="en0"),
                        mock.patch.object(eb.time, "sleep")]
        for p in self.patches:
            p.start()

    def tearDown(self):
        for p in self.patches:
            p.stop()

    def test_boost_reconnects_until_good_and_logs(self):
        seq = [sample("2.4GHz", 500, fast=["157"]), sample("2.4GHz", 450, fast=["157"]), sample("5GHz", 6)]
        with mock.patch.object(eb, "measure", side_effect=seq), \
                mock.patch.object(eb, "reconnect", return_value=True) as rc:
            before, best, ok = eb.do_boost(tries=3, verbose=False)
        self.assertTrue(ok)
        self.assertEqual(rc.call_count, 2)
        self.assertEqual(best["link"]["band"], "5GHz")
        logged = eb.load(eb.BOOSTS)
        self.assertEqual(len(logged), 1)
        self.assertEqual(logged[0]["tries"], 2)

    def test_boost_skips_when_already_good(self):
        with mock.patch.object(eb, "measure", return_value=sample("5GHz", 5)), \
                mock.patch.object(eb, "reconnect") as rc:
            _, _, ok = eb.do_boost(verbose=False)
        self.assertTrue(ok)
        rc.assert_not_called()
        self.assertEqual(eb.load(eb.BOOSTS), [])

    def test_boost_gives_up_and_keeps_best(self):
        seq = [sample("2.4GHz", 500, fast=["157"]), sample("2.4GHz", 300, fast=["157"]), sample("2.4GHz", 400, fast=["157"])]
        with mock.patch.object(eb, "measure", side_effect=seq), mock.patch.object(eb, "reconnect", return_value=True):
            _, best, ok = eb.do_boost(tries=2, verbose=False)
        self.assertFalse(ok)
        self.assertEqual(best["gw_ms"], 300)

    def test_log_rotation(self):
        with mock.patch.object(eb, "MAX_LOG_BYTES", 2000):
            for i in range(100):
                eb.append(eb.SAMPLES, sample(gw=i))
        self.assertLess(os.path.getsize(os.path.join(self.tmp, eb.SAMPLES)), 2000)
        self.assertEqual(eb.load(eb.SAMPLES)[-1]["gw_ms"], 99)


class CliTests(unittest.TestCase):
    def test_non_macos_refuses(self):
        with mock.patch.object(eb.sys, "platform", "linux"):
            self.assertEqual(eb.main(["status"]), 1)


@unittest.skipUnless(sys.platform == "darwin", "installer is macOS-only")
class InstallerTests(unittest.TestCase):
    def run_sh(self, script, home, *args, stdin=None):
        env = {**os.environ, "HOME": home, "EDUROAM_BOOST_DRY_RUN": "1"}
        return subprocess.run(["bash", os.path.join(ROOT, script), *args], env=env, input=stdin,
                              capture_output=True, text=True, check=True)

    def test_install_watch_and_uninstall(self):
        home = tempfile.mkdtemp()
        self.run_sh("install.sh", home, "--watch-auto")
        cmd = os.path.join(home, ".local/bin/eduroam-boost")
        self.assertEqual(subprocess.run([cmd, "--version"], capture_output=True, text=True).stdout.strip(), eb.VERSION)
        plist = os.path.join(home, "Library/LaunchAgents/io.github.lucasyanzy.eduroam-boost.plist")
        with open(plist) as fh:
            body = fh.read()
        self.assertIn("<string>--auto</string>", body)
        self.run_sh("uninstall.sh", home, "--purge")
        self.assertFalse(os.path.exists(cmd) or os.path.exists(plist))

    def test_curl_pipe_install_without_watch(self):
        home = tempfile.mkdtemp()
        env = {**os.environ, "HOME": home, "EDUROAM_BOOST_DRY_RUN": "1", "EDUROAM_BOOST_RAW": "file://" + ROOT}
        with open(os.path.join(ROOT, "install.sh")) as fh:
            subprocess.run(["bash", "-s", "--", "--no-watch"], stdin=fh, env=env, check=True, capture_output=True)
        self.assertTrue(os.path.exists(os.path.join(home, ".local/share/eduroam-boost/eduroam_boost.py")))
        self.assertFalse(os.path.exists(os.path.join(home, "Library/LaunchAgents")))


if __name__ == "__main__":
    unittest.main()
